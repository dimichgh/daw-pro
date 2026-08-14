import CoreGraphics
import Foundation
import DAWCore

/// The piano roll's **viewport navigator** (m25-b-2): the whole clip's notes drawn
/// into a small corner box, with a rectangle marking the part of it the editor is
/// currently showing, and the click/drag arithmetic that re-aims the editor at a
/// point on that box.
///
/// ⚠️ **This is NOT `MIDIMapGeometry`, and that type could not be extended into
/// it.** `MIDIMapGeometry` is the arrange clip block's note THUMBNAIL — its
/// vertical axis is SPAN-RELATIVE (`pitchFraction(_:lo:hi:)` maps the clip's own
/// `[lo, hi]` across the full height), which is right for a decoration whose only
/// job is "show where the sound sits" and **disqualifying for a navigator**. Two
/// reasons, both fatal: a viewport rectangle drawn in a span-relative space is
/// unbounded (the visible pitch window is routinely wider than the note span, so
/// the rect runs off both ends of the box), and the mapping RESCALES whenever the
/// note span changes — so the map would move under the pointer mid-drag. This type
/// therefore uses an **ABSOLUTE pitch axis (0...127, high at top)**, identical to
/// the roll's own content space, which makes the mapping constant for the whole
/// gesture and the viewport rect exactly as big as the window really is.
///
/// **One producer, honoured:** note pills are NOT re-derived from beats and
/// pitches here. They are `PianoRollModel.noteRect` — the roll's single producer of
/// a note's content rectangle, the same rect a click hit-tests and the marquee
/// intersects — projected through one scale. A second spelling of beat→x here would
/// be a map that disagrees with the grid it navigates.
///
/// Pure value geometry: no SwiftUI, no actor state, `Equatable`, headless-tested
/// (the `WaveformScale` / `EditorMaximize` precedent — `DAWApp` has no test target,
/// so anything that DECIDES lives here).
public struct PianoRollMinimap: Sendable, Equatable {

    // MARK: - Drawn size

    /// The box's default drawn size. Wide-and-short on purpose: the axis a user
    /// navigates most is TIME, and a map tall enough to resolve single semitones
    /// would be a panel, not a corner overlay.
    public static let defaultSize = CGSize(width: 176, height: 56)

    /// Smallest drawn pill. At the box's scale a 1/16 note is a fraction of a point
    /// wide and one semitone a fraction of a point tall, so without a floor the map
    /// of a real clip renders as nothing at all. The floor is a VISIBILITY device
    /// and is deliberately not carried into any hit test — nothing on this surface
    /// hit-tests a note (the map navigates; the grid edits).
    public static let minPillWidth: CGFloat = 1
    public static let minPillHeight: CGFloat = 1.5

    /// Smallest drawn viewport rectangle. A deeply zoomed-in editor shows a sliver
    /// of a long clip; below a few points the rectangle stops reading as a window
    /// and starts reading as a hairline artefact.
    public static let minViewportSide: CGFloat = 8

    // MARK: - Inputs

    /// The box the map draws into.
    public var size: CGSize
    /// The roll's full content extent, in the roll's own content points. Width is
    /// the grid's DRAWN width (`PianoRollModel.drawnWidth`) — which includes the
    /// m18-f/m19-g shaded latent zone past the clip end, because notes legitimately
    /// live there and a navigator that could not reach them would be a map with the
    /// edge of the world drawn in the wrong place.
    public var contentWidth: CGFloat
    /// Full pitch stack height (`PianoRollModel.contentHeight` — all 128 rows).
    public var contentHeight: CGFloat

    public init(size: CGSize = PianoRollMinimap.defaultSize,
                contentWidth: CGFloat,
                contentHeight: CGFloat) {
        self.size = CGSize(width: max(0, size.width), height: max(0, size.height))
        self.contentWidth = max(0, contentWidth)
        self.contentHeight = max(0, contentHeight)
    }

    // MARK: - Scale

    /// Content x → box x. The divisor floors at 1 so an empty/degenerate content
    /// extent cannot divide by zero; at that size there is nothing to draw anyway.
    public var scaleX: CGFloat { size.width / max(1, contentWidth) }
    /// Content y → box y.
    public var scaleY: CGFloat { size.height / max(1, contentHeight) }

    /// Projects a rect from the roll's content space into the box.
    public func project(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
               width: rect.width * scaleX, height: rect.height * scaleY)
    }

    // MARK: - Note pills

    /// One note's pill in box coordinates, or nil when the box has no area to draw
    /// in. Floors at the minimum pill size so a short note or a single semitone is
    /// still ink, and is trimmed at the box's right edge so a latent note far past
    /// the content extent cannot paint outside the map.
    public func pillRect(for note: MIDINote,
                         rowHeight: CGFloat, pixelsPerBeat: CGFloat) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let content = PianoRollModel.noteRect(note, rowHeight: rowHeight,
                                              pixelsPerBeat: pixelsPerBeat)
        var box = project(content)
        box.size.width = max(Self.minPillWidth, box.width)
        box.size.height = max(Self.minPillHeight, box.height)
        guard box.minX < size.width else { return nil }
        box.size.width = min(box.width, size.width - box.minX)
        box.origin.y = min(box.minY, max(0, size.height - box.height))
        box.origin.y = max(0, box.minY)
        return box
    }

    /// Every note's pill, in note order. Notes with no visible extent are dropped.
    ///
    /// Resolved ONCE per geometry change by the view and handed to the Canvas as a
    /// finished array — never recomputed inside the draw closure. The viewport
    /// rectangle moves on every scroll report and, while follow drives, on every
    /// transport tick, so a map that re-walked the note list per frame would put a
    /// continuous allocation on the playback path (the `PianoRollGrid` rule:
    /// closure-free, tick-stable inputs).
    public func pillRects(_ notes: [MIDINote],
                          rowHeight: CGFloat, pixelsPerBeat: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        out.reserveCapacity(notes.count)
        for note in notes {
            if let r = pillRect(for: note, rowHeight: rowHeight, pixelsPerBeat: pixelsPerBeat) {
                out.append(r)
            }
        }
        return out
    }

    // MARK: - The viewport rectangle

    /// The part of the content the editor is showing, in box coordinates.
    ///
    /// Driven by the scrollers' REPORTED offsets, never by an assumed or predicted
    /// value — including during a live drag on this very surface. The reported
    /// offset cannot desync from the scroller and it self-clamps at the content
    /// edges, so the rectangle stops at the end of the map exactly when the editor
    /// stops scrolling; a pointer-driven rectangle would keep travelling and claim
    /// a scroll that never happened. The cost is a frame of lag behind the pointer,
    /// which is the honest trade.
    public func viewportRect(scrollX: CGFloat, scrollY: CGFloat,
                             viewportWidth: CGFloat, viewportHeight: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let w = min(size.width, max(Self.minViewportSide, max(0, viewportWidth) * scaleX))
        let h = min(size.height, max(Self.minViewportSide, max(0, viewportHeight) * scaleY))
        let x = (max(0, scrollX) * scaleX).clamped(to: 0...max(0, size.width - w))
        let y = (max(0, scrollY) * scaleY).clamped(to: 0...max(0, size.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Click / drag → scroll offsets

    /// The scroll offsets that CENTRE the editor's viewport on a point in the box.
    ///
    /// **ONE rule for both gestures — press and drag both centre on the pointer.**
    /// The rejected alternative was the two-mode navigator (press inside the
    /// rectangle drags it by a grab offset; press outside jumps): it needs a hit
    /// test, per-gesture state, and it makes the identical gesture mean two things
    /// depending on where it started — which fails the beginner test for a control
    /// whose whole promise is "point at where you want to be." At this box size the
    /// displacement a centring press can cause is bounded by half the rectangle.
    ///
    /// The point is clamped into the box first, so a drag that travels off the map
    /// keeps scrubbing at the edge instead of dying. Both axes clamp to
    /// `FollowPlayhead.maxOffset` — the SAME ceiling the scrollers themselves
    /// present, so the map can never ask for an offset the editor will refuse and
    /// then draw a rectangle where the editor is not.
    public func scrollTarget(forPoint point: CGPoint,
                             viewportWidth: CGFloat, viewportHeight: CGFloat) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let px = point.x.clamped(to: 0...size.width)
        let py = point.y.clamped(to: 0...size.height)
        let contentX = px / scaleX
        let contentY = py / scaleY
        let maxX = FollowPlayhead.maxOffset(contentWidth: contentWidth,
                                            viewportWidth: max(0, viewportWidth))
        let maxY = FollowPlayhead.maxOffset(contentWidth: contentHeight,
                                            viewportWidth: max(0, viewportHeight))
        let x = (contentX - max(0, viewportWidth) / 2).clamped(to: 0...maxX)
        let y = (contentY - max(0, viewportHeight) / 2).clamped(to: 0...maxY)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Follow-playhead precedence (the decision, stated here so it is testable)

    /// Whether a minimap jump should be delivered through the **manual-scroll**
    /// seam (`FollowPlayheadModel.scrollExternally`) rather than through follow's
    /// own target path. Always true — and it is a constant with a name rather than
    /// an unwritten habit at the call site, because it IS the precedence decision:
    ///
    /// **A minimap jump is a manual scroll. The user wins, and follow stands down
    /// on this surface only.**
    ///
    /// The consequences all fall out of policy that already shipped
    /// (`FollowPlayhead` — "a manual scroll during playback SUSPENDS follow on that
    /// surface until the transport is started again, or the chip is clicked"):
    /// while playing, the offset the scroller reports back is one follow never
    /// asked for, so `reportOffset` suspends and the follow chip drops to its
    /// PAUSED face — the fight is visible instead of silent. While stopped nothing
    /// is contesting the scroll, so nothing is suspended.
    ///
    /// ⚠️ **`PanelLayoutStore.followPlayhead` is deliberately NOT touched.** That
    /// flag is the one persisted ENABLE shared with the arrange workspace; turning
    /// it off to win a piano-roll gesture would stand follow down on a surface the
    /// user never touched, and would outlive the gesture by every future session.
    /// Suspension is per-surface runtime state and re-arms by itself on the next
    /// play — which is what "the user wins THIS scroll" should mean.
    public static let jumpIsAManualScroll = true
}
