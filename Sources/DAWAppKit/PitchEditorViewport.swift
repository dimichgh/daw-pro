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

    /// m23-ap I5 — the horizontal offset the scroller can actually SHOW: the
    /// measured `offset.x` pulled into `0 ... maxOffset.x`. The time ruler draws
    /// with it and its ticks add it, so the ruler's numbers stay on the lines they
    /// name.
    ///
    /// ⚠️ **THE MEASURED `offset.x` CAN BE A POSITION THE SCROLLER IS NOT AT.**
    /// MEASURED 2026-09-25 (staging): scroll to 900 at 160 pt/beat, zoom out until
    /// the whole clip fits (content 1083 pt in a 1364 pt box, so the only
    /// position is 0), then zoom out AGAIN (TIME −): the horizontal reader reports
    /// 900 and keeps reporting it, while the grid is drawn at 0. A `scrollTo`
    /// issued while the content fits makes the reported frame revert to the
    /// scroller's last real position — the family the m17-b durability note on
    /// the horizontal writer describes. Before this clamp the ruler drew bar 8
    /// over the clip's first bar and a click on it landed 28 beats late.
    ///
    /// Deliberately NOT applied inside the reader: `contentSize` arrives in its
    /// own `onChange` and can be one pass stale during a zoom-in, so a clamp there
    /// would cut a real offset down to the OLD content's limit — a silent wrong
    /// pinch anchor (I2) in exchange for a visible ruler fix. The root, no
    /// `scrollTo` while the new content fits, is BUILT (I0-F, W7-NTU:
    /// `timeZoomOffset` returns nil there); this clamp stays as the net, because
    /// the root's effect on the reader is proven only in a drawn window.
    public var shownOffsetX: CGFloat { clamped(offset).x }
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
/// one from `MagnifyGesture.Value.startLocation` on its first tick
/// (`PitchEditorViewport.pinchAnchor`, through `PitchEditorPinch.tick`).
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
    ///
    /// ⭐ **I0-F — `nil` WHEN THE NEW CONTENT FITS THE VIEWPORT.** There is then
    /// ONE position (0) and nothing to re-pin, so the pane issues no `scrollTo`
    /// at all. MEASURED 2026-09-25 (`shownOffsetX`'s note, and W6 I5-F1-F's run
    /// B): a `scrollTo` issued while the content fits left SwiftUI's horizontal
    /// reader reporting the scroller's last REAL position (900) at the second
    /// zoom in 36 of 57 repetitions, while the grid drew at 0. The scroller
    /// needs no write to get there: a clip view whose document is narrower
    /// than itself has no other origin. What this rule proves headlessly is
    /// only that the pane asks for no scroll; that the scroller then sits at 0
    /// and the reader stays true across the second fit-zoom is a DRAWN-window
    /// fact, and `shownOffsetX`'s clamp stays as the net under it.
    public func timeZoomOffset(geometry: PitchEditorGeometry, oldPPB: CGFloat, newPPB: CGFloat,
                               playheadProjectBeat: Double,
                               pointerAnchor: PitchEditorZoomAnchor? = nil) -> CGFloat? {
        guard abs(newPPB - oldPPB) > 0.0001, viewportSize.width > 0 else { return nil }
        var atNew = geometry
        atNew.pixelsPerBeat = newPPB
        let limit = FollowPlayhead.maxOffset(contentWidth: atNew.contentWidth,
                                             viewportWidth: viewportSize.width)
        // I0-F: the new content fits — one position, no write (see above).
        guard limit > 0 else { return nil }
        let anchor = pointerAnchor
            ?? timeZoomAnchor(geometry: geometry, oldPPB: oldPPB,
                              playheadProjectBeat: playheadProjectBeat)
        let raw = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: anchor.ppb, newPPB: newPPB,
            oldOffset: anchor.offset, anchorScreenX: anchor.screenX)
        return min(raw, limit)
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

// MARK: - The pinch (I2, design §5)

extension PitchEditorViewport {

    /// The anchor a pinch holds for its whole life, measured from the gesture's
    /// `startLocation` at the scale and offset it started at.
    ///
    /// `startLocation` is a CONTENT-space point: the gesture hangs on the
    /// surface inside the horizontal scroller, the space the drag and the hover
    /// report in. Its viewport-local x is the screen position that must not
    /// move — the roll's `startLocation.x - gridScrollX`, through `local(_:)`.
    public func pinchAnchor(startLocation: CGPoint, ppb: CGFloat) -> PitchEditorZoomAnchor {
        PitchEditorZoomAnchor(ppb: ppb, offset: offset.x, screenX: local(startLocation).x)
    }
}

extension PitchEditorZoomAnchor {

    /// The scale a pinch tick asks for: the GESTURE-START scale times the
    /// gesture's magnification, on the pane's own ladder range.
    ///
    /// ⚠️ **MAGNIFICATION IS CUMULATIVE** — `MagnifyGesture` reports the ratio
    /// since the gesture began, not since the last tick — so this multiplies the
    /// anchor's `ppb`, never the slot's current value. Compounding from the
    /// current value would square the zoom on the second tick and cube it on the
    /// third. The `0.001` floor is the arrange's guard
    /// (`ArrangeZoom.PinchState.zoomed`); a non-finite ratio asks for no change,
    /// so the rule is total like `PitchEditorViewport.clamped`.
    public func pinchedPPB(magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite else { return PianoRollZoom.clamp(ppb) }
        return PianoRollZoom.clamp(ppb * max(magnification, 0.001))
    }
}

/// One pinch tick, as a pure reducer: the view's whole `MagnifyGesture.onChanged`
/// policy with the gesture and the scroll view taken out, so "captured ONCE" is a
/// test rather than a comment.
///
/// ⭐ **THE OFFSET IS NOT HERE, AND THAT IS THE DESIGN.** A tick asks for a SCALE
/// only. The pane's one re-pin funnel (the ppb slot's `onChange` →
/// `timeZoomOffset(pointerAnchor:)`) turns the returned anchor into the offset, so
/// a pinch and a zoom button share one writer of the scroll and no ordering
/// question arises between two of them (`PianoRollView.gridPinch`'s rule).
public enum PitchEditorPinch {

    /// - Parameters:
    ///   - anchor: the anchor this gesture already captured, or `nil` on its
    ///     first tick. ⛔ **ONLY `nil` CAPTURES.** A live anchor is returned
    ///     unchanged whatever the viewport and the scale are now — they are the
    ///     pinch's OWN not-yet-landed output, and measuring from them is the drift
    ///     the capture exists to prevent.
    ///   - viewport: where the scrollers are looking now (read on capture only).
    ///   - startLocation: the gesture's start point, content space (read on
    ///     capture only — a real gesture's is fixed for its life anyway).
    ///   - currentPPB: the slot's scale now (read on capture only).
    ///   - magnification: the gesture's cumulative ratio.
    public static func tick(anchor: PitchEditorZoomAnchor?, viewport: PitchEditorViewport,
                            startLocation: CGPoint, currentPPB: CGFloat,
                            magnification: CGFloat) -> (anchor: PitchEditorZoomAnchor, ppb: CGFloat) {
        let captured = anchor ?? viewport.pinchAnchor(startLocation: startLocation, ppb: currentPPB)
        return (captured, captured.pinchedPPB(magnification: magnification))
    }
}

/// The zoom cluster's DRAWN help (design §5: "the zoom cluster reads 'Pinch to
/// zoom time', drawn, never a tooltip"). One home, so the view draws it and the
/// chrome ledger reports the very string drawn — a tooltip is invisible to
/// `view.capture`, the `EQCurveEditor.help` lesson.
public enum PitchEditorZoomHint {
    /// Beside the TIME buttons. "time" because the pinch zooms that axis only;
    /// PITCH stays on its buttons (design §13).
    public static let pinchTime = "Pinch to zoom time"
}
