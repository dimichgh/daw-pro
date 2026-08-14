import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m25-b-2 — the piano roll's viewport navigator: the mapping, the viewport
/// rectangle, the click/drag arithmetic, and the follow-playhead precedence.
///
/// The VIEW half lives in `DAWApp`, which has no test target; the wiring pins that
/// close that gap are `PianoRollMinimapSiteTests`. Everything that DECIDES is here.
@MainActor
@Suite("Piano-roll viewport minimap (m25-b-2)")
struct PianoRollMinimapTests {

    /// A roll one bar wide at the default scales: 4 beats × 32 pt = 128 pt of
    /// content, 128 rows × 14 pt = 1792 pt of pitch stack.
    private static let rowHeight: CGFloat = PianoRollModel.defaultRowHeight       // 14
    private static let ppb: CGFloat = PianoRollModel.defaultPixelsPerBeat         // 32
    private static let stackHeight: CGFloat = 128 * PianoRollModel.defaultRowHeight

    private static func map(contentWidth: CGFloat = 1280,
                            contentHeight: CGFloat = stackHeight,
                            size: CGSize = PianoRollMinimap.defaultSize) -> PianoRollMinimap {
        PianoRollMinimap(size: size, contentWidth: contentWidth, contentHeight: contentHeight)
    }

    // MARK: - Scale

    @Test("Scale maps the whole content onto the whole box, on both axes")
    func scaleSpansTheContent() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        #expect(abs(1280 * m.scaleX - m.size.width) < 0.001)
        #expect(abs(1792 * m.scaleY - m.size.height) < 0.001)
    }

    @Test("A degenerate content extent cannot divide by zero")
    func zeroContentIsSafe() {
        let m = Self.map(contentWidth: 0, contentHeight: 0)
        #expect(m.scaleX.isFinite)
        #expect(m.scaleY.isFinite)
        #expect(m.scaleX > 0)
        #expect(m.scaleY > 0)
    }

    // MARK: - Note pills: the ABSOLUTE pitch axis

    /// The decision that separates this type from `MIDIMapGeometry`. If the axis
    /// ever became span-relative, these two notes would land at the box's bottom
    /// and top edges instead of near its middle — and the viewport rectangle would
    /// stop meaning anything.
    @Test("Pitch maps ABSOLUTELY (0...127), not relative to the notes' own span")
    func pitchAxisIsAbsolute() {
        let m = Self.map()
        let low = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let high = MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1)
        let lowRect = m.pillRect(for: low, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        let highRect = m.pillRect(for: high, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        #expect(lowRect != nil)
        #expect(highRect != nil)
        // Two semitones apart out of 128 rows: a hair under 1 pt on a 56 pt box.
        // Span-relative mapping would have put them a full box-height apart.
        let gap = lowRect!.minY - highRect!.minY
        #expect(gap > 0)                 // higher pitch is nearer the top
        #expect(gap < 2)                 // and only two rows' worth away
        // Middle C sits near the vertical middle of the FULL stack, always —
        // whatever else the clip contains.
        #expect(abs(lowRect!.minY - m.size.height * CGFloat(127 - 60) / 128) < 0.5)
    }

    @Test("Pills come out of the roll's ONE note-rect producer, scaled")
    func pillsProjectTheRollsOwnRect() {
        let m = Self.map()
        let note = MIDINote(pitch: 72, startBeat: 6, lengthBeats: 4)
        let content = PianoRollModel.noteRect(note, rowHeight: Self.rowHeight,
                                              pixelsPerBeat: Self.ppb)
        let pill = m.pillRect(for: note, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        #expect(pill != nil)
        #expect(abs(pill!.minX - content.minX * m.scaleX) < 0.001)
        #expect(abs(pill!.minY - content.minY * m.scaleY) < 0.001)
        // 4 beats × 32 = 128 content pt, well over the visibility floor, so the
        // width here is the true projection rather than the floor.
        #expect(abs(pill!.width - content.width * m.scaleX) < 0.001)
    }

    @Test("A very short note and a single row still draw — the visibility floor")
    func shortNotesStayVisible() {
        let m = Self.map()
        let tiny = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 0.01)
        let pill = m.pillRect(for: tiny, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        #expect(pill != nil)
        #expect(pill!.width >= PianoRollMinimap.minPillWidth)
        #expect(pill!.height >= PianoRollMinimap.minPillHeight)
        // Without the floor this would be sub-point on both axes — i.e. nothing.
        #expect(0.01 * Self.ppb * m.scaleX < PianoRollMinimap.minPillWidth)
        #expect(Self.rowHeight * m.scaleY < PianoRollMinimap.minPillHeight)
    }

    @Test("No pill paints outside the box, on either axis")
    func pillsStayInsideTheBox() {
        let m = Self.map(contentWidth: 1280)
        // A note at the very end of the content, and one PAST it (the m18-f/m19-g
        // latent zone is inside `contentWidth`, but a note can outrun even that
        // between an edit and the next width recompute).
        let atEnd = MIDINote(pitch: 127, startBeat: 39, lengthBeats: 1)     // ends at 1280
        let past = MIDINote(pitch: 0, startBeat: 80, lengthBeats: 4)        // way past
        let endPill = m.pillRect(for: atEnd, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        #expect(endPill != nil)
        #expect(endPill!.maxX <= m.size.width + 0.001)
        #expect(endPill!.minY >= 0)
        #expect(endPill!.maxY <= m.size.height + 0.001)
        #expect(m.pillRect(for: past, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb) == nil)
    }

    @Test("The lowest pitch's pill is trimmed to sit inside the bottom edge")
    func lowestPitchStaysInside() {
        let m = Self.map()
        let bottom = MIDINote(pitch: 0, startBeat: 0, lengthBeats: 1)
        let pill = m.pillRect(for: bottom, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        #expect(pill != nil)
        #expect(pill!.maxY <= m.size.height + 0.001)
    }

    @Test("No notes, no pills — and an empty box draws nothing at all")
    func emptyCases() {
        let m = Self.map()
        #expect(m.pillRects([], rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb).isEmpty)
        let flat = Self.map(size: CGSize(width: 0, height: 0))
        let note = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        #expect(flat.pillRect(for: note, rowHeight: Self.rowHeight,
                              pixelsPerBeat: Self.ppb) == nil)
    }

    @Test("Every note in the list gets a pill, in order")
    func pillsPreserveOrder() {
        let m = Self.map()
        let notes = (0..<8).map { MIDINote(pitch: 60 + $0, startBeat: Double($0), lengthBeats: 1) }
        let pills = m.pillRects(notes, rowHeight: Self.rowHeight, pixelsPerBeat: Self.ppb)
        #expect(pills.count == 8)
        // Rising pitch AND rising time: x grows, y shrinks, monotonically.
        for i in 1..<pills.count {
            #expect(pills[i].minX > pills[i - 1].minX)
            #expect(pills[i].minY < pills[i - 1].minY)
        }
    }

    // MARK: - The viewport rectangle

    @Test("A viewport showing everything fills the whole box")
    func fullViewportFillsTheBox() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let r = m.viewportRect(scrollX: 0, scrollY: 0, viewportWidth: 1280, viewportHeight: 1792)
        #expect(abs(r.width - m.size.width) < 0.001)
        #expect(abs(r.height - m.size.height) < 0.001)
        #expect(r.minX == 0)
        #expect(r.minY == 0)
    }

    @Test("The rectangle tracks the scroll offsets proportionally")
    func rectTracksScroll() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let r = m.viewportRect(scrollX: 640, scrollY: 896,
                               viewportWidth: 320, viewportHeight: 448)
        #expect(abs(r.minX - m.size.width / 2) < 0.001)
        #expect(abs(r.minY - m.size.height / 2) < 0.001)
        #expect(abs(r.width - m.size.width / 4) < 0.001)
        #expect(abs(r.height - m.size.height / 4) < 0.001)
    }

    @Test("A deeply zoomed viewport keeps a readable minimum, still inside the box")
    func rectHasAFloorAndStaysInside() {
        let m = Self.map(contentWidth: 40000, contentHeight: 1792)
        let r = m.viewportRect(scrollX: 39900, scrollY: 0,
                               viewportWidth: 100, viewportHeight: 448)
        #expect(r.width >= PianoRollMinimap.minViewportSide)
        // The floor must not push it out the right-hand edge — the failure that
        // makes a navigator lie about where you are.
        #expect(r.maxX <= m.size.width + 0.001)
        #expect(r.minX >= 0)
    }

    @Test("An over-large or negative scroll offset cannot escape the box")
    func rectClampsAbsurdOffsets() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let far = m.viewportRect(scrollX: 99999, scrollY: 99999,
                                 viewportWidth: 320, viewportHeight: 448)
        #expect(far.maxX <= m.size.width + 0.001)
        #expect(far.maxY <= m.size.height + 0.001)
        let negative = m.viewportRect(scrollX: -500, scrollY: -500,
                                      viewportWidth: 320, viewportHeight: 448)
        #expect(negative.minX == 0)
        #expect(negative.minY == 0)
    }

    // MARK: - Click / drag → scroll offsets

    @Test("Pressing the middle centres the editor on the middle")
    func pressCentres() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let t = m.scrollTarget(forPoint: CGPoint(x: m.size.width / 2, y: m.size.height / 2),
                               viewportWidth: 320, viewportHeight: 448)
        // Content centre 640 minus half a viewport = 480; 896 − 224 = 672.
        #expect(abs(t.x - 480) < 0.001)
        #expect(abs(t.y - 672) < 0.001)
    }

    /// The round trip that makes the control feel right: press the middle, then
    /// draw the rectangle from where the editor landed — it should be centred.
    @Test("Press → scroll → rectangle lands centred on the press")
    func pressRoundTrips() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let point = CGPoint(x: m.size.width * 0.5, y: m.size.height * 0.5)
        let t = m.scrollTarget(forPoint: point, viewportWidth: 320, viewportHeight: 448)
        let r = m.viewportRect(scrollX: t.x, scrollY: t.y,
                               viewportWidth: 320, viewportHeight: 448)
        #expect(abs(r.midX - point.x) < 0.001)
        #expect(abs(r.midY - point.y) < 0.001)
    }

    @Test("Pressing the far edges clamps to the ends of the content, never past")
    func pressClampsAtBothEnds() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let start = m.scrollTarget(forPoint: CGPoint(x: 0, y: 0),
                                   viewportWidth: 320, viewportHeight: 448)
        #expect(start.x == 0)
        #expect(start.y == 0)
        let end = m.scrollTarget(forPoint: CGPoint(x: m.size.width, y: m.size.height),
                                 viewportWidth: 320, viewportHeight: 448)
        #expect(abs(end.x - (1280 - 320)) < 0.001)
        #expect(abs(end.y - (1792 - 448)) < 0.001)
    }

    /// The ceiling is `FollowPlayhead.maxOffset` — the same producer the scrollers
    /// themselves clamp to. A second spelling here would let the map ask for an
    /// offset the editor refuses and then draw a rectangle where the editor is not.
    @Test("The clamp ceiling IS FollowPlayhead.maxOffset, not a private copy")
    func clampSharesTheScrollersCeiling() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let end = m.scrollTarget(forPoint: CGPoint(x: m.size.width, y: m.size.height),
                                 viewportWidth: 320, viewportHeight: 448)
        #expect(end.x == FollowPlayhead.maxOffset(contentWidth: 1280, viewportWidth: 320))
        #expect(end.y == FollowPlayhead.maxOffset(contentWidth: 1792, viewportWidth: 448))
    }

    @Test("Content that fits entirely on screen has nowhere to scroll")
    func shortContentCannotScroll() {
        let m = Self.map(contentWidth: 200, contentHeight: 300)
        let t = m.scrollTarget(forPoint: CGPoint(x: m.size.width, y: m.size.height),
                               viewportWidth: 400, viewportHeight: 600)
        #expect(t.x == 0)
        #expect(t.y == 0)
    }

    /// A drag that leaves the map keeps scrubbing at the edge instead of dying —
    /// the difference between a navigator you can throw to the end of the part and
    /// one that stops the moment your hand overshoots by a pixel.
    @Test("A drag that travels off the map keeps scrubbing at the edge")
    func offMapDragClampsRatherThanStops() {
        let m = Self.map(contentWidth: 1280, contentHeight: 1792)
        let past = m.scrollTarget(forPoint: CGPoint(x: m.size.width + 400,
                                                    y: m.size.height + 400),
                                  viewportWidth: 320, viewportHeight: 448)
        let atEdge = m.scrollTarget(forPoint: CGPoint(x: m.size.width, y: m.size.height),
                                    viewportWidth: 320, viewportHeight: 448)
        #expect(past == atEdge)
        let before = m.scrollTarget(forPoint: CGPoint(x: -400, y: -400),
                                    viewportWidth: 320, viewportHeight: 448)
        #expect(before.x == 0)
        #expect(before.y == 0)
    }

    @Test("A zero-sized box asks for no scroll at all")
    func flatBoxIsInert() {
        let flat = Self.map(size: CGSize(width: 0, height: 0))
        #expect(flat.scrollTarget(forPoint: CGPoint(x: 10, y: 10),
                                  viewportWidth: 320, viewportHeight: 448) == .zero)
        #expect(flat.viewportRect(scrollX: 10, scrollY: 10,
                                  viewportWidth: 320, viewportHeight: 448) == .zero)
    }

    // MARK: - Follow-playhead precedence (the decision, exercised on the real model)

    /// **The precedence contract, run through the actual runtime rather than
    /// asserted in prose:** delivering a jump through the manual-scroll seam makes
    /// the resulting landing read as the USER, so follow stands down on this
    /// surface. The chip's PAUSED face follows from `isSuspended`.
    @Test("A minimap jump while PLAYING suspends follow on that surface")
    func jumpWhilePlayingSuspendsFollow() {
        let follow = FollowPlayheadModel()
        // Establish the baseline the way the view does: one report on mount.
        follow.reportOffset(0, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        #expect(follow.isSuspended == false)

        // The jump: through `scrollExternally`, exactly as `jumpToMinimapTarget`
        // delivers it — no `expectedOffset` update, no issue in flight.
        follow.scrollExternally(to: 480)
        #expect(follow.externalScrollX == 480)
        // The scroller lands and reports back, as `gridScrollReader` does.
        follow.reportOffset(480, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        #expect(follow.isSuspended == true)
    }

    /// The negative control: the same jump through follow's OWN target path would
    /// NOT suspend, because the landing is one follow asked for. Without this, the
    /// test above could pass for a model that suspends on every report.
    @Test("A scroll follow ITSELF asked for does not suspend it")
    func followsOwnScrollDoesNotSuspend() {
        let follow = FollowPlayheadModel()
        follow.reportOffset(0, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        let target = follow.target(isEnabled: true, isPlaying: true, playheadX: 900,
                                   viewportWidth: 320, contentWidth: 1280, currentOffset: 0)
        #expect(target != nil)
        follow.reportOffset(target!, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        #expect(follow.isSuspended == false)
    }

    @Test("A minimap jump while STOPPED suspends nothing — there is no fight to win")
    func jumpWhileStoppedSuspendsNothing() {
        let follow = FollowPlayheadModel()
        follow.reportOffset(0, isEnabled: true, isPlaying: false,
                            contentWidth: 1280, viewportWidth: 320)
        follow.scrollExternally(to: 480)
        follow.reportOffset(480, isEnabled: true, isPlaying: false,
                            contentWidth: 1280, viewportWidth: 320)
        #expect(follow.isSuspended == false)
    }

    @Test("Suspension re-arms on the next play — the jump does not outlive itself")
    func suspensionIsTemporary() {
        let follow = FollowPlayheadModel()
        follow.reportOffset(0, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        follow.scrollExternally(to: 480)
        follow.reportOffset(480, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        #expect(follow.isSuspended == true)
        follow.rearm()
        #expect(follow.isSuspended == false)
    }

    /// ⚠️ The half a passing suspension test cannot see: that the jump did not
    /// achieve its stand-down by switching the SHARED persisted enable off, which
    /// would have stood the arrange down too and outlived the gesture forever.
    @Test("A jump never touches the shared persisted followPlayhead flag")
    func jumpLeavesTheSharedEnableAlone() {
        let store = PanelLayoutStore()
        store.setFollowPlayhead(true)
        let follow = FollowPlayheadModel()
        follow.reportOffset(0, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        follow.scrollExternally(to: 480)
        follow.reportOffset(480, isEnabled: true, isPlaying: true,
                            contentWidth: 1280, viewportWidth: 320)
        #expect(follow.isSuspended == true)
        #expect(store.followPlayhead == true)      // the ENABLE is untouched
    }

    @Test("The precedence decision is recorded where a reader will find it")
    func precedenceIsRecorded() {
        #expect(PianoRollMinimap.jumpIsAManualScroll == true)
    }

    // MARK: - Visibility persistence

    @Test("The map ships SHOWN, and a dismissal write-throughs")
    func visibilityPersists() {
        let backing = InMemoryPanelLayoutBacking()
        let store = PanelLayoutStore(backing: backing)
        #expect(store.pianoRollMinimap == true)
        store.setPianoRollMinimap(false)
        #expect(store.pianoRollMinimap == false)
        // The reason it is persisted at all: the roll is mounted `.id(clip.id)`, so
        // a view-local flag would come back on the next clip switch. A fresh store
        // over the SAME backing is that reload.
        let reloaded = PanelLayoutStore(backing: backing)
        #expect(reloaded.pianoRollMinimap == false)
    }

    @Test("Reset restores the map")
    func resetRestoresTheMap() {
        let store = PanelLayoutStore()
        store.setPianoRollMinimap(false)
        store.reset()
        #expect(store.pianoRollMinimap == PanelLayoutStore.defaultPianoRollMinimap)
        #expect(store.pianoRollMinimap == true)
    }

    @Test("Visibility is its own slot — toggling it moves nothing else")
    func visibilityIsIndependent() {
        let store = PanelLayoutStore()
        let fraction = store.editorFraction
        let ppb = store.pianoRollPPB
        let maximized = store.editorMaximized
        store.setPianoRollMinimap(false)
        #expect(store.editorFraction == fraction)
        #expect(store.pianoRollPPB == ppb)
        #expect(store.editorMaximized == maximized)
    }

    // MARK: - The pointer affordance

    @Test("The map wears the movable-body hand, opening at rest and closing on drag")
    func cursorFamily() {
        #expect(CursorAffordance.minimapViewport.restCursor == .grab)
        #expect(CursorAffordance.minimapViewport.dragCursor == .grabbing)
    }
}
