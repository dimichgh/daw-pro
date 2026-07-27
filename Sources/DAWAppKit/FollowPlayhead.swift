import CoreGraphics
import Foundation
import Observation
import DAWCore

/// Follow-the-playhead ("catch") geometry — m23-c2. Pure value math, shared by
/// EVERY surface that follows: the arrange lanes and all three piano-roll bands.
/// One policy is why follow is one item and not one per surface — the in-frame
/// margin, the landing position and the no-op rules are decided here once, so two
/// surfaces can never disagree about when a page turns.
///
/// **Page, not continuous — MEASURED, not assumed (m23-c2).** Both policies were
/// built and driven through the SAME 8 bars of real playback on the same session
/// (6 tracks × 16 clips, 100 pt/beat, a 1090 pt viewport over 7200 pt of content),
/// counting the churn signals the lanes already reported before this item existed:
///
/// | | scrolls issued | offset reports | content-width changes | main-actor round trip p50 / p95 |
/// |---|---|---|---|---|
/// | page | 4 | 4 | 0 | **15 / 21 ms** |
/// | continuous | 262 | 262 | 0 | **49 / 61 ms** |
///
/// Continuous costs 65× the scroll traffic and **3.3× the main-actor latency** —
/// on a ~33 ms transport tick, a main actor answering in 49 ms is already behind
/// the cadence it is supposed to be following. (The sampler itself got 119 replies
/// in the page run and only 100 in the continuous one, in the same wall-clock
/// window: the same fact from the other side.)
///
/// **The content-width column is why the comparison is honest**: 0 in BOTH,
/// because every target is clamped to `contentWidth − viewport`, which makes the
/// lanes' `totalBeats` zoom padding a no-op. Without that clamp, continuous would
/// also have re-laid-out the entire lane stack 30×/second, and the measurement
/// would have been against a strawman nobody would ship.
///
/// Continuous also has no honest implementation on the macOS 14 floor: the native
/// scroller has no pixel-precise offset API there (`ScrollPosition(x:y:)` is
/// macOS 15+), so every tick has to re-lay-out a layout-real anchor inside the
/// scroll content — which is exactly the 262 scrolls above.
public enum FollowPlayhead {

    /// Where the playhead lands after a page turn, as a fraction of the viewport
    /// from its leading edge. Deliberately NOT 0: landing the playhead exactly on
    /// the leading edge hides the bar it just played, and the eye loses the
    /// approach. A small lead-in keeps one beat of context behind it.
    public static let leadFraction: CGFloat = 0.12

    /// How close to a viewport edge the playhead may drift before a page turns.
    /// Capped at a quarter viewport so a narrow panel still turns pages instead
    /// of chattering (a margin wider than half the viewport has no interior).
    public static let edgeMargin: CGFloat = 32

    /// Landing tolerance: a computed target this close to where the scroller
    /// already sits is NOT worth a scroll. This is also what makes the ends of
    /// the timeline quiet — once the scroller is pinned at `maxOffset` the
    /// playhead keeps advancing into the last viewport, the clamped target stops
    /// changing, and follow correctly does nothing.
    public static let landTolerance: CGFloat = 0.5

    /// How far a reported offset may sit from the offset follow last asked for
    /// before it is read as the USER having scrolled. A couple of points of slack
    /// absorbs scroller rounding without swallowing a real drag.
    public static let manualScrollTolerance: CGFloat = 2

    /// The furthest left edge a scroller can present: content minus one viewport.
    public static func maxOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    /// The PAGE policy: nil while the playhead is comfortably in frame, else the
    /// scroll offset that lands it `leadFraction` in from the leading edge.
    ///
    /// - Parameters:
    ///   - playheadX: the playhead's x in the scroller's CONTENT space.
    ///   - viewportWidth: the visible width of that scroller.
    ///   - contentWidth: the scroller's laid-out content width (the clamp's ceiling —
    ///     clamping here is what keeps follow from ever growing the content, and so
    ///     from invalidating the lanes' layout on a page turn).
    ///   - currentOffset: where the scroller sits right now (ground truth, reported
    ///     by the view's own geometry — never an assumed value).
    public static func pageOffset(playheadX: CGFloat, viewportWidth: CGFloat,
                                  contentWidth: CGFloat, currentOffset: CGFloat) -> CGFloat? {
        guard viewportWidth > 1 else { return nil }
        let margin = min(edgeMargin, viewportWidth / 4)
        let inFrame = (currentOffset + margin)...(currentOffset + viewportWidth - margin)
        if inFrame.contains(playheadX) { return nil }
        return landing(playheadX: playheadX, viewportWidth: viewportWidth,
                       contentWidth: contentWidth, currentOffset: currentOffset)
    }

    /// The shared landing computation: the clamped target, or nil when it is where
    /// the scroller already is. Backwards is symmetric with forwards — a loop wrap
    /// or a rewind pages BACK by the same rule, so follow never leaves the playhead
    /// behind the viewport.
    private static func landing(playheadX: CGFloat, viewportWidth: CGFloat,
                                contentWidth: CGFloat, currentOffset: CGFloat) -> CGFloat? {
        let ceiling = maxOffset(contentWidth: contentWidth, viewportWidth: viewportWidth)
        let target = (playheadX - viewportWidth * leadFraction).clamped(to: 0...ceiling)
        return abs(target - currentOffset) < landTolerance ? nil : target
    }
}

/// The per-surface follow RUNTIME (m23-c2): the suspension state, the offset
/// follow last asked for, and the churn counters the mode measurement reads.
/// One instance per scrolling surface (the arrange lanes, the piano-roll bands) —
/// scrolling the roll must not suspend the arrange — while the ENABLE flag they
/// all read is the one persisted `PanelLayoutStore.followPlayhead` slot.
///
/// **Manual-scroll policy (stated, because every DAW has to choose): a manual
/// scroll during playback SUSPENDS follow on that surface until the transport is
/// started again (or the chip is clicked).** The view never fights the pointer.
/// Suspension is visible — the chip drops to its PAUSED face — because a control
/// that claims to be following while it is not is the dishonest-readout class this
/// project keeps closing.
///
/// SwiftUI-free (this target has no SwiftUI): views feed it geometry and consume
/// the target it returns.
@MainActor
@Observable
public final class FollowPlayheadModel {

    /// Suspended by a manual scroll — observed, because the chip renders it.
    public private(set) var isSuspended = false

    /// The offset follow last ASKED the scroller for (clamped). The manual-scroll
    /// detector compares reports against this; nil until follow has issued one.
    @ObservationIgnored public private(set) var expectedOffset: CGFloat?

    /// The last offset the surface actually REPORTED (ground truth from its own
    /// geometry, never an analytic value). The `debug.followPlayhead` echo reads
    /// this, so a gate asserts against what the scroller did, not what we asked for.
    @ObservationIgnored public private(set) var reportedOffset: CGFloat = 0
    /// The geometry as last seen — echoed for the same reason.
    public var contentWidth: CGFloat { lastContentWidth }
    public var viewportWidth: CGFloat { lastViewportWidth }

    /// True between issuing a scroll and the first report that follows it. That
    /// first report is never read as a manual scroll: the scroller may land
    /// slightly off (or clamp) for reasons that are not the user.
    @ObservationIgnored private var issueInFlight = false

    /// Geometry as of the last call. A change here is a resize / zoom / edit, NOT
    /// a user scroll — the detector re-baselines instead of suspending, so a
    /// window resize can never silently switch follow off.
    @ObservationIgnored private var lastContentWidth: CGFloat = 0
    @ObservationIgnored private var lastViewportWidth: CGFloat = 0
    /// Whether any geometry has been observed since the last counter reset — the
    /// first observation ESTABLISHES the baseline and is not a change.
    @ObservationIgnored private var hasGeometry = false
    /// Whether any offset has ever been reported. Until one has, follow has no
    /// idea where the surface sits and cannot attribute a move to anyone.
    @ObservationIgnored private var hasReported = false

    // MARK: Churn counters (the mode measurement's ground truth)

    /// Scrolls follow has issued since the last reset.
    @ObservationIgnored public private(set) var scrollCount = 0
    /// Live scroll-offset reports seen since the last reset (the ruler-mirror /
    /// re-render churn signal).
    @ObservationIgnored public private(set) var offsetReportCount = 0
    /// Content-width changes seen since the last reset (the layout-invalidation
    /// signal — follow's clamp is what holds this at zero).
    @ObservationIgnored public private(set) var contentWidthChangeCount = 0

    public init() {}

    /// The offset this surface should scroll to now, or nil for "stay put".
    /// Call from the TRANSPORT observation path (`onChange` of the position), never
    /// from a layout callback: a `scrollTo` issued inside a layout transaction moves
    /// layout without durably updating the scroller's internal position (m17-b,
    /// measured), and any later forced re-render then jumps.
    public func target(isEnabled: Bool, isPlaying: Bool, playheadX: CGFloat,
                       viewportWidth: CGFloat, contentWidth: CGFloat,
                       currentOffset: CGFloat) -> CGFloat? {
        noteGeometry(contentWidth: contentWidth, viewportWidth: viewportWidth)
        guard isEnabled, isPlaying, !isSuspended else { return nil }
        guard let offset = FollowPlayhead.pageOffset(
            playheadX: playheadX, viewportWidth: viewportWidth,
            contentWidth: contentWidth, currentOffset: currentOffset) else { return nil }
        expectedOffset = offset
        issueInFlight = true
        scrollCount += 1
        return offset
    }

    /// The scroller's LIVE offset, reported by the view's own geometry. This is the
    /// manual-scroll detector: armed only while playing, with follow enabled, no
    /// issue in flight, and unchanged geometry — every other divergence has a cause
    /// that is not the user.
    public func reportOffset(_ offset: CGFloat, isEnabled: Bool, isPlaying: Bool,
                             contentWidth: CGFloat, viewportWidth: CGFloat) {
        offsetReportCount += 1
        reportedOffset = offset
        defer { hasReported = true }
        let geometryChanged = noteGeometry(contentWidth: contentWidth, viewportWidth: viewportWidth)
        guard isEnabled, isPlaying, !geometryChanged, !isSuspended else {
            expectedOffset = offset
            issueInFlight = false
            return
        }
        guard let expected = expectedOffset else {
            expectedOffset = offset
            return
        }
        if abs(offset - expected) > FollowPlayhead.manualScrollTolerance {
            if issueInFlight {
                // The landing of a scroll WE asked for — the scroller clamped or
                // rounded. Take its answer as the new truth; do not blame the user.
                issueInFlight = false
                expectedOffset = offset
            } else {
                isSuspended = true
            }
        } else {
            issueInFlight = false
            expectedOffset = offset
        }
    }

    /// A scroll this surface should perform that follow did NOT ask for — the seam
    /// a debug-tier gate uses to reproduce a POINTER drag on either following
    /// surface (`debug.followPlayhead {simulateUserScroll}`, the `debug.*Seed`
    /// precedent). Deliberately leaves `expectedOffset` alone: what makes a drag a
    /// drag, as far as the detector can ever know, is that the offset the scroller
    /// reports back is one follow never asked for — which is exactly what this
    /// produces, through the same GeometryReader report a real drag travels on.
    @ObservationIgnored public private(set) var externalScrollX: CGFloat = 0
    /// Observed, because the views watch it to apply the scroll.
    public private(set) var externalScrollNonce = 0

    public func scrollExternally(to x: CGFloat) {
        externalScrollX = max(0, x)
        externalScrollNonce += 1
    }

    /// Re-arms follow: the transport started, or the user clicked the chip back on.
    ///
    /// The baseline is KEPT, not cleared. Re-arming means "follow may drive this
    /// surface again", never "forget where the surface is" — and this line used to
    /// say `expectedOffset = nil`, which left the first drag after every play
    /// unjudged: with no baseline the detector could only record where the drag
    /// landed, and the next transport tick then yanked the view back instead of
    /// standing down. Found live by the m23-c2 gate, on the roll, on exactly the
    /// path a user takes (press play, scroll).
    public func rearm() {
        isSuspended = false
        issueInFlight = false
        expectedOffset = hasReported ? reportedOffset : nil
    }

    /// Zeroes the churn counters (the measurement seam). Also drops the geometry
    /// baseline, so the first observation after a reset establishes rather than
    /// counts.
    public func resetCounters() {
        scrollCount = 0
        offsetReportCount = 0
        contentWidthChangeCount = 0
        hasGeometry = false
    }

    /// Records geometry and reports whether it MOVED since the last call.
    @discardableResult
    private func noteGeometry(contentWidth: CGFloat, viewportWidth: CGFloat) -> Bool {
        let widthMoved = abs(contentWidth - lastContentWidth) > 0.5
        let changed = widthMoved || abs(viewportWidth - lastViewportWidth) > 0.5
        // The first observation is a baseline, not a change. Counting it reports a
        // layout invalidation that never happened — and this counter's only job is
        // to answer whether FOLLOW invalidated layout, so a phantom in it is worse
        // than no counter at all (it cost this item one false gate failure).
        if widthMoved, hasGeometry { contentWidthChangeCount += 1 }
        hasGeometry = true
        lastContentWidth = contentWidth
        lastViewportWidth = viewportWidth
        return changed
    }
}
