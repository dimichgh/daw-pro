import Testing
import CoreGraphics
@testable import DAWAppKit

/// m23-c2 — the shared follow-the-playhead policy + per-surface runtime. These
/// pin the contract BOTH following surfaces read: the arrange lanes and the three
/// piano-roll bands compute their page turns here, so a divergence between them
/// would have to be a wiring bug, never a policy one.
@MainActor
@Suite("Follow the playhead (m23-c2)")
struct FollowPlayheadTests {

    // Geometry used throughout: a 1000 pt viewport over 8000 pt of content.
    private let viewport: CGFloat = 1000
    private let content: CGFloat = 8000

    // MARK: - The page policy

    @Test("a playhead comfortably in frame does NOT scroll")
    func inFrameIsQuiet() {
        // Viewport [0, 1000], margin 32 → the quiet window is [32, 968].
        for x in [CGFloat(40), 500, 900, 960] {
            #expect(FollowPlayhead.pageOffset(playheadX: x, viewportWidth: viewport,
                                              contentWidth: content, currentOffset: 0) == nil,
                    "x=\(x) should be in frame")
        }
    }

    @Test("crossing the trailing margin turns the page and lands the playhead at the lead-in")
    func pageTurnForward() {
        // x = 970 is past the trailing margin (968) → page.
        let target = FollowPlayhead.pageOffset(playheadX: 970, viewportWidth: viewport,
                                               contentWidth: content, currentOffset: 0)
        // Lands leadFraction (12%) in from the leading edge: 970 − 120 = 850.
        #expect(target == 850)
        // …and from there it is quiet again for most of a viewport.
        #expect(FollowPlayhead.pageOffset(playheadX: 1000, viewportWidth: viewport,
                                          contentWidth: content, currentOffset: 850) == nil)
    }

    @Test("a backward jump (loop wrap / rewind) pages BACK by the same rule")
    func pageTurnBackward() {
        // Scrolled to 4000, the transport wraps to beat 0 (x = 0) — off the
        // leading edge, so follow must chase it backwards, not strand it.
        let target = FollowPlayhead.pageOffset(playheadX: 0, viewportWidth: viewport,
                                               contentWidth: content, currentOffset: 4000)
        #expect(target == 0)
    }

    @Test("the target is CLAMPED to the content — follow never grows the timeline")
    func clampedToContent() {
        // This clamp is load-bearing, not cosmetic: the lanes pad their content to
        // `viewport + hScrollApplyTarget` (TimelineLanesView `totalBeats`), so an
        // unclamped follow target would re-lay-out the whole lane stack on every
        // page turn.
        let maxOffset = FollowPlayhead.maxOffset(contentWidth: content, viewportWidth: viewport)
        #expect(maxOffset == 7000)
        let target = FollowPlayhead.pageOffset(playheadX: 7990, viewportWidth: viewport,
                                               contentWidth: content, currentOffset: 0)
        #expect(target == 7000)
    }

    @Test("pinned at the end, the last viewport is quiet (no scroll storm)")
    func endOfTimelineIsQuiet() {
        // Scroller at maxOffset, playhead running out the last viewport: every
        // clamped target equals where it already is → nil, every tick.
        for x in [CGFloat(7500), 7900, 7999] {
            #expect(FollowPlayhead.pageOffset(playheadX: x, viewportWidth: viewport,
                                              contentWidth: content, currentOffset: 7000) == nil,
                    "x=\(x) at the end should not scroll")
        }
    }

    @Test("content shorter than the viewport never scrolls")
    func shortContent() {
        #expect(FollowPlayhead.pageOffset(playheadX: 400, viewportWidth: viewport,
                                          contentWidth: 500, currentOffset: 0) == nil)
    }

    @Test("a degenerate viewport is a no-op, never a divide-by-zero")
    func degenerateViewport() {
        #expect(FollowPlayhead.pageOffset(playheadX: 100, viewportWidth: 0,
                                          contentWidth: content, currentOffset: 0) == nil)
    }

    @Test("the in-frame margin never exceeds a quarter viewport")
    func narrowViewportStillTurnsPages() {
        // At 80 pt the flat 32 pt margin would leave a 16 pt interior and chatter;
        // capped at viewport/4 = 20, the window is [20, 60].
        #expect(FollowPlayhead.pageOffset(playheadX: 40, viewportWidth: 80,
                                          contentWidth: content, currentOffset: 0) == nil)
        #expect(FollowPlayhead.pageOffset(playheadX: 70, viewportWidth: 80,
                                          contentWidth: content, currentOffset: 0) != nil)
    }

    // MARK: - The runtime: enable / playback gating

    @Test("follow is inert while disabled, while stopped, and while suspended")
    func gating() {
        let model = FollowPlayheadModel()
        // Off.
        #expect(model.target(isEnabled: false, isPlaying: true, playheadX: 5000,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 0) == nil)
        // On, but stopped: follow keeps the playhead in frame DURING PLAYBACK.
        #expect(model.target(isEnabled: true, isPlaying: false, playheadX: 5000,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 0) == nil)
        // On + playing → scrolls.
        #expect(model.target(isEnabled: true, isPlaying: true, playheadX: 5000,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 0) == 4880)
    }

    // MARK: - The manual-scroll policy

    @Test("a manual scroll during playback SUSPENDS follow until it is re-armed")
    func manualScrollSuspends() {
        let model = FollowPlayheadModel()
        // Follow issues a scroll and the scroller lands on it.
        let target = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                                  viewportWidth: viewport, contentWidth: content,
                                  currentOffset: 0)
        #expect(target == 850)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended == false)

        // Now the USER drags the scroller somewhere else.
        model.reportOffset(3000, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended)

        // The view does not fight back: no target while suspended, even though the
        // playhead is now far off-screen.
        #expect(model.target(isEnabled: true, isPlaying: true, playheadX: 1200,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 3000) == nil)

        // Re-arm (transport restarted, or the chip clicked) and it follows again.
        model.rearm()
        #expect(model.isSuspended == false)
        #expect(model.target(isEnabled: true, isPlaying: true, playheadX: 1200,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 3000) != nil)
    }

    @Test("the FIRST report after a follow scroll never suspends (the scroller may clamp)")
    func clampedLandingIsNotAManualScroll() {
        let model = FollowPlayheadModel()
        _ = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                         viewportWidth: viewport, contentWidth: content, currentOffset: 0)
        // The scroller lands 40 pt short of the ask — clamping/rounding, not a user.
        model.reportOffset(810, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended == false)
        // But the NEXT divergence, with nothing in flight, is the user.
        model.reportOffset(2000, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended)
    }

    @Test("a RESIZE / zoom / edit re-baselines instead of suspending")
    func geometryChangeNeverSuspends() {
        let model = FollowPlayheadModel()
        _ = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                         viewportWidth: viewport, contentWidth: content, currentOffset: 0)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        // The window is resized: the offset jumps AND the geometry moved. Blaming
        // the user here would silently switch follow off on a window drag.
        model.reportOffset(2400, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: 1400)
        #expect(model.isSuspended == false)
        #expect(model.expectedOffset == 2400)
    }

    @Test("scrolling while STOPPED never suspends — the detector is playback-armed")
    func stoppedScrollNeverSuspends() {
        let model = FollowPlayheadModel()
        _ = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                         viewportWidth: viewport, contentWidth: content, currentOffset: 0)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        // Browsing the arrangement with the transport stopped is not a fight.
        model.reportOffset(5000, isEnabled: true, isPlaying: false,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended == false)
        // …and the baseline moved with it, so the next play does not read the
        // browse as a manual scroll.
        #expect(model.expectedOffset == 5000)
    }

    @Test("a drag BEFORE follow has issued anything still suspends (the re-arm baseline)")
    func dragBeforeAnyFollowScrollSuspends() {
        // The live path this pins: press PLAY (which re-arms), then scroll before
        // the playhead has reached an edge — so follow has issued nothing yet.
        // `rearm` used to clear the baseline, which left this drag unattributable;
        // the next tick then paged the view back and the pointer lost. Caught by
        // the m23-c2 gate on the piano roll.
        let model = FollowPlayheadModel()
        // The surface reports its resting position on appearance (both surfaces do,
        // from their own GeometryReader, with `initial: true`).
        model.reportOffset(0, isEnabled: true, isPlaying: false,
                           contentWidth: content, viewportWidth: viewport)
        model.rearm()
        #expect(model.scrollCount == 0, "follow has issued nothing yet — that is the point")
        // Now the user drags, while playing, with the playhead still comfortably
        // in frame.
        model.reportOffset(4000, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended)
        #expect(model.target(isEnabled: true, isPlaying: true, playheadX: 200,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 4000) == nil,
                "and follow must not page the view back out from under the drag")
    }

    @Test("a scroll follow was never CONTESTING does not suspend it")
    func notDrivingNeverSuspends() {
        // `isEnabled` here is "follow is driving THIS surface", not the persisted
        // flag: the piano roll passes false while the transport sits outside the
        // edited clip (m23-c1 — no line to keep in frame, so `target` issues
        // nothing). Suspending on that scroll would drop the chip to its PAUSED
        // face for a fight that never happened.
        let model = FollowPlayheadModel()
        _ = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                         viewportWidth: viewport, contentWidth: content, currentOffset: 0)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        // Transport leaves the clip; the user scrolls the grid.
        model.reportOffset(4200, isEnabled: false, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended == false)
        // …and the baseline moved with it, so re-entering the clip does not read
        // that browse as a manual scroll either.
        #expect(model.expectedOffset == 4200)
        #expect(model.target(isEnabled: true, isPlaying: true, playheadX: 5200,
                             viewportWidth: viewport, contentWidth: content,
                             currentOffset: 4200) != nil)
    }

    @Test("scroller rounding within tolerance is not a manual scroll")
    func toleranceAbsorbsRounding() {
        let model = FollowPlayheadModel()
        _ = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                         viewportWidth: viewport, contentWidth: content, currentOffset: 0)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        model.reportOffset(851, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.isSuspended == false)
    }

    // MARK: - Churn counters (the mode measurement's ground truth)

    @Test("counters record issued scrolls, offset reports and content-width changes")
    func counters() {
        let model = FollowPlayheadModel()
        _ = model.target(isEnabled: true, isPlaying: true, playheadX: 970,
                         viewportWidth: viewport, contentWidth: content, currentOffset: 0)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: content, viewportWidth: viewport)
        #expect(model.scrollCount == 1)
        #expect(model.offsetReportCount == 2)
        // The FIRST observation of the geometry is a baseline, not a change: this
        // counter answers "did follow invalidate layout", and a phantom in it reads
        // as a relayout that never happened.
        #expect(model.contentWidthChangeCount == 0)
        // A real change counts.
        model.reportOffset(850, isEnabled: true, isPlaying: true,
                           contentWidth: 9000, viewportWidth: viewport)
        #expect(model.contentWidthChangeCount == 1)

        model.resetCounters()
        #expect(model.scrollCount == 0)
        #expect(model.offsetReportCount == 0)
        #expect(model.contentWidthChangeCount == 0)
    }

    @Test("a whole viewport of playback issues ONE scroll, not one per tick")
    func pageQuietnessUnderASweep() {
        // The measured difference between page and continuous, as a unit test: walk
        // the playhead across a full viewport at the transport's ~30 Hz and count
        // how many scrolls the policy asks for. Continuous asked for 262 over 8 bars
        // where page asked for 4 (see `FollowPlayhead`'s table) — the shape of that
        // is right here: one page turn, then silence until the next edge.
        let model = FollowPlayheadModel()
        var offset: CGFloat = 0
        // 30 Hz over ~4 s at 120 bpm × 100 pt/beat ≈ 2 pt per tick.
        for tick in 0..<600 {
            let x = CGFloat(tick) * 2
            if let target = model.target(isEnabled: true, isPlaying: true, playheadX: x,
                                         viewportWidth: viewport, contentWidth: content,
                                         currentOffset: offset) {
                offset = target
                model.reportOffset(offset, isEnabled: true, isPlaying: true,
                                   contentWidth: content, viewportWidth: viewport)
            }
        }
        // 1200 pt of travel over a 1000 pt viewport: one turn, and only one.
        #expect(model.scrollCount == 1)
    }
}
