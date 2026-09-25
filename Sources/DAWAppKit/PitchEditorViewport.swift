import CoreGraphics
import Foundation

// m23-ap interaction batch, item I0 — THE VIEWPORT SEAM.
//
// Design record: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §3
// (decision D0). Before I0 the pane's two nested scroll views had no offset
// reader, no programmatic writer and no zoom re-pin (finding F7), so a zoom
// rescaled the content under a scroll offset that stayed put in POINTS — the
// view jumped about the clip start — and a pointer-anchored pinch (I2), a
// following playhead (I5) and autoscroll (I6b) were all impossible.
//
// This file is the pure half: WHERE the pane is looking, as a value, and the
// re-pin arithmetic every zoom driver shares. The view reads the offsets with
// the roll's `gridScrollReader` idiom, writes them with the roll's marker idiom,
// and hands both to this type; every I2/I5/I6b policy takes it as an argument,
// so all of them are headless-testable.
//
// ⭐ **NO ARITHMETIC IS NEW HERE.** The anchor rule is
// `ArrangeZoom.offsetPreservingAnchor`; the "playhead if in frame, else the
// centre" choice is `PianoRollZoom.anchorScreenX`; the vertical centre is
// `PianoRollZoom.rowAnchorScreenY`; the clamp is `FollowPlayhead.maxOffset`.
// This type only composes them against the PITCH EDITOR's own content.

/// Where the pitch editor's scrollers are looking, as a pure VALUE.
///
/// Every field is MEASURED by the view — `offset` by the two scroll readers,
/// `viewportSize` by the two scrollers' own frames, `contentSize` by the laid-out
/// surface — and reported through `PitchEditorInteractionBridge`, which is where
/// `debug.pitchEditor`'s `viewport` echo reads it. Nothing re-derives it.
public struct PitchEditorViewport: Sendable, Equatable {
    /// The live scroll offset, in CONTENT points at the viewport's top-leading
    /// corner: x from the horizontal scroller, y from the vertical one.
    public var offset: CGPoint
    /// The visible box: the horizontal scroller's width (the surface past the
    /// pitch ruler) × the vertical scroller's height.
    public var viewportSize: CGSize
    /// The scrolled content: the surface as laid out (`contentWidth` ×
    /// `contentHeight` of the geometry it was drawn with).
    public var contentSize: CGSize

    public init(offset: CGPoint = .zero, viewportSize: CGSize = .zero,
                contentSize: CGSize = .zero) {
        self.offset = offset
        self.viewportSize = viewportSize
        self.contentSize = contentSize
    }

    /// Nothing measured yet — the pane has not been laid out.
    public static let unmeasured = PitchEditorViewport()

    /// Whether the viewport has been laid out. A zero box has no anchor to hold:
    /// its "centre" would be a fake one (the roll's guard, `repinZoomAnchor`).
    public var isMeasured: Bool { viewportSize.width > 0 && viewportSize.height > 0 }

    /// The furthest each axis can scroll: `FollowPlayhead.maxOffset` per axis, so
    /// a content smaller than its viewport scrolls nowhere (0), never backwards.
    public var maxOffset: CGPoint {
        CGPoint(x: FollowPlayhead.maxOffset(contentWidth: contentSize.width,
                                            viewportWidth: viewportSize.width),
                y: FollowPlayhead.maxOffset(contentWidth: contentSize.height,
                                            viewportWidth: viewportSize.height))
    }

    /// A CONTENT-space point (what the surface's gestures and hover report) in
    /// VIEWPORT-local points — where it sits on screen inside the scroller.
    public func local(_ contentPoint: CGPoint) -> CGPoint {
        CGPoint(x: contentPoint.x - offset.x, y: contentPoint.y - offset.y)
    }

    /// The inverse: a viewport-local point in content space.
    public func content(_ localPoint: CGPoint) -> CGPoint {
        CGPoint(x: localPoint.x + offset.x, y: localPoint.y + offset.y)
    }

    /// `proposed` pulled into `0 ... maxOffset` on both axes.
    ///
    /// ⚠️ **EVERY WRITER OF A SCROLL TARGET GOES THROUGH A CLAMP, AND THAT IS A
    /// LAYOUT RULE, NOT TIDINESS.** The view's writers are the roll's marker
    /// idiom: a clear spacer as long as the target, mounted as an `.overlay` on
    /// content of the content's own length. An overlay is sized to its parent, so
    /// a target past the end would be a marker longer than the content, and
    /// `scrollTo` would land somewhere other than the value asked for
    /// (`PianoRollView.verticalJumpMarker`'s warning, on both axes here).
    public func clamped(_ proposed: CGPoint) -> CGPoint {
        let limit = maxOffset
        return CGPoint(x: min(max(0, proposed.x.isFinite ? proposed.x : 0), limit.x),
                       y: min(max(0, proposed.y.isFinite ? proposed.y : 0), limit.y))
    }
}

// MARK: - The zoom re-pin (I0, design §3 item 4)

/// The point a TIME zoom holds still: its viewport-relative x, and the scale and
/// offset it was measured at — the three arguments
/// `ArrangeZoom.offsetPreservingAnchor` takes, and nothing else (the roll's
/// private `ZoomAnchorBase`, made a value here so I2 can hand one in).
///
/// ⚠️ **A NON-NIL ANCHOR HANDED TO `timeZoomOffset` MEANS "A GESTURE OWNS THE
/// ANCHOR".** A pinch is cumulative, so every tick must re-pin the anchor it
/// captured at the gesture's START — deriving it afresh per tick feeds the zoom's
/// own not-yet-landed scroll back into it and the beat under the pointer wanders
/// (`PianoRollView.ZoomAnchorBase`'s doc; the arrange's `PinchState`). I2 builds
/// one from `MagnifyGesture.Value.startLocation` on its first tick.
public struct PitchEditorZoomAnchor: Sendable, Equatable {
    /// The pixels-per-beat the anchor was measured at.
    public var ppb: CGFloat
    /// The horizontal scroll offset it was measured at.
    public var offset: CGFloat
    /// The anchor's VIEWPORT-relative x — the screen position that must not move.
    public var screenX: CGFloat

    public init(ppb: CGFloat, offset: CGFloat, screenX: CGFloat) {
        self.ppb = ppb
        self.offset = offset
        self.screenX = screenX
    }
}

extension PitchEditorViewport {

    /// The anchor a NON-POINTER time zoom holds (the zoom buttons, ⌘+/⌘−/⌘0, the
    /// `debug.panelLayout` seam): the playhead's screen x when the transport is
    /// inside this clip AND in frame, else the viewport centre — the roll's rule,
    /// through the roll's function (`PianoRollZoom.anchorScreenX`, whose `nil`
    /// is the m23-c1 off-clip case).
    ///
    /// ⛔⛔ **MEASURED AT THE OLD SCALE, AND THAT IS WHY THIS TAKES `oldPPB`
    /// RATHER THAN A PLAYHEAD X.** The pane re-pins from the ppb slot's
    /// `onChange`, and by the time any code runs there the geometry may already
    /// carry the NEW scale. The playhead's content x at the new scale minus the
    /// OLD offset is a plausible number and the wrong anchor: the content then
    /// slides exactly as far as the zoom step, and every rule test still passes
    /// because the rules are right and only the argument is wrong
    /// (`PianoRollView.playheadLineX(atPPB:)` records the same trap). So the
    /// measurement happens HERE, on a copy of `geometry` rescaled to `oldPPB` —
    /// whatever scale the caller's geometry carries. Pinned by
    /// `PitchEditorViewportTests`, whose plant measures at the new scale.
    public func timeZoomAnchor(geometry: PitchEditorGeometry, oldPPB: CGFloat,
                               playheadProjectBeat: Double) -> PitchEditorZoomAnchor {
        var atOld = geometry
        atOld.pixelsPerBeat = oldPPB
        // The ONE beat→x mapping (`PitchEditorGeometry.x(forProjectBeat:)`), at
        // the old scale; `nil` off-clip, where no line is drawn to hold.
        let playheadX: CGFloat? = atOld.isInsideClip(projectBeat: playheadProjectBeat)
            ? atOld.x(forProjectBeat: playheadProjectBeat) : nil
        return PitchEditorZoomAnchor(
            ppb: oldPPB, offset: offset.x,
            screenX: PianoRollZoom.anchorScreenX(playheadContentX: playheadX, offset: offset.x,
                                                 viewportWidth: viewportSize.width))
    }

    /// The horizontal offset that keeps the anchor's beat at the anchor's screen x
    /// after a time zoom `oldPPB → newPPB`, or `nil` when there is nothing to
    /// re-pin: the scale did not move (the `initial` call, a clamped press at
    /// either end of the ladder) or the viewport has not been laid out.
    ///
    /// - Parameters:
    ///   - geometry: the pane's geometry at EITHER scale — it supplies the clip's
    ///     span and the one beat→x mapping; both scales are applied here.
    ///   - pointerAnchor: a gesture's captured anchor (I2's pinch), which wins
    ///     over the playhead/centre rule for the whole gesture. `nil` for every
    ///     non-pointer driver.
    ///
    /// Clamped to the NEW content's `maxOffset` (see `clamped(_:)` for why a
    /// writer must never ask for more): zooming OUT near the end can need an
    /// offset the shorter content no longer has, and the anchor then gives way —
    /// the one case where it cannot hold, exactly as the floor at 0 is on the
    /// left.
    public func timeZoomOffset(geometry: PitchEditorGeometry, oldPPB: CGFloat, newPPB: CGFloat,
                               playheadProjectBeat: Double,
                               pointerAnchor: PitchEditorZoomAnchor? = nil) -> CGFloat? {
        guard abs(newPPB - oldPPB) > 0.0001, viewportSize.width > 0 else { return nil }
        let anchor = pointerAnchor
            ?? timeZoomAnchor(geometry: geometry, oldPPB: oldPPB,
                              playheadProjectBeat: playheadProjectBeat)
        let raw = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: anchor.ppb, newPPB: newPPB,
            oldOffset: anchor.offset, anchorScreenX: anchor.screenX)
        var atNew = geometry
        atNew.pixelsPerBeat = newPPB
        return min(raw, FollowPlayhead.maxOffset(contentWidth: atNew.contentWidth,
                                                 viewportWidth: viewportSize.width))
    }

    /// The vertical offset that keeps the pitch at the viewport's CENTRE ROW under
    /// the centre after a row-height zoom, or `nil` when there is nothing to
    /// re-pin (no change, or no laid-out viewport).
    ///
    /// ⚠️⚠️ **NOT `PianoRollZoom.rowZoomOffset`, THOUGH DESIGN §3 NAMES IT — THE
    /// SOURCE CONTRADICTS THE DESIGN HERE.** That function clamps against
    /// `PianoRollModel.pitchCount × newRowHeight`: the ROLL's content, 128 rows,
    /// always. This pane's content is its pitch WINDOW, 12–36 rows
    /// (`PitchEditorGeometry.contentHeight`), so the roll's clamp would be a
    /// clamp that never engages — a plausible, wrong number at exactly the edge
    /// where the vertical marker's overlay argument needs it. The ARITHMETIC is
    /// still borrowed, call for call: the same anchor rule, the same centre, the
    /// same clamp function — against this pane's NEW content height.
    ///
    /// ⚠️ **m23-ap I6c: A ROW ZOOM CAN MOVE THE WINDOW'S TOP.** The pane's pitch
    /// window is filled to the pane at the current row height
    /// (`PitchEditorRange.filled`), so a row zoom adds or removes rows ABOVE the
    /// notes as well as below them. The borrowed arithmetic assumes the top row
    /// stays put, and when it does not, the anchor is off by exactly the rows
    /// that moved there. So a caller whose window changed hands the OLD window in
    /// `oldMidiRange`, and the anchor is then measured through the geometry's own
    /// midi↔y mapping: the pitch under the centre at the old row height and
    /// window, placed at the new ones. With no `oldMidiRange`, or an unchanged
    /// one, this is the borrowed arithmetic exactly as before.
    public func rowZoomOffset(geometry: PitchEditorGeometry, oldRowHeight: CGFloat,
                              newRowHeight: CGFloat,
                              oldMidiRange: ClosedRange<Double>? = nil) -> CGFloat? {
        guard abs(newRowHeight - oldRowHeight) > 0.0001, viewportSize.height > 0 else { return nil }
        let anchorY = PianoRollZoom.rowAnchorScreenY(viewportHeight: viewportSize.height)
        var atNew = geometry
        atNew.rowHeight = newRowHeight
        let raw: CGFloat
        if let oldMidiRange, oldMidiRange != atNew.midiRange {
            var atOld = geometry
            atOld.rowHeight = oldRowHeight
            atOld.midiRange = oldMidiRange
            let anchorMidi = atOld.midi(forY: offset.y + anchorY)
            raw = max(0, atNew.y(forMidi: anchorMidi) - anchorY)
        } else {
            raw = ArrangeZoom.offsetPreservingAnchor(
                oldPPB: oldRowHeight, newPPB: newRowHeight, oldOffset: offset.y,
                anchorScreenX: anchorY)
        }
        return min(raw, FollowPlayhead.maxOffset(contentWidth: atNew.contentHeight,
                                                 viewportWidth: viewportSize.height))
    }
}
