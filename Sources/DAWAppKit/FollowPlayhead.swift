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

    // MARK: - The VERTICAL axis: reveal, not page (m34-a-3)

    /// Where a vertical reveal should land, and which edge it lands against.
    /// The edge is carried rather than re-derived by the caller because the
    /// arrange applies its vertical scroll through `ScrollViewProxy.scrollTo(
    /// _:anchor:)` on the destination ROW's id — the `debug.arrangeScroll`
    /// precedent — so the anchor is part of the answer, not a detail of it.
    public struct RowReveal: Equatable, Sendable {
        /// The scroll offset this reveal corresponds to, clamped. Fed to the
        /// manual-scroll detector as the expected offset; the proxy's landing
        /// is then absorbed as an in-flight issue rather than blamed on the user.
        public var offset: CGFloat
        /// True when the row is BELOW the viewport and should land against its
        /// bottom edge; false when it is above and should land against the top.
        public var anchorsBottom: Bool
    }

    /// ⭐⭐ **THE VERTICAL POLICY, AND IT IS DELIBERATELY NOT `pageOffset`.**
    ///
    /// The horizontal axis follows a playhead that moves on its own and would
    /// leave the frame every few seconds if nothing turned the page; landing it
    /// `leadFraction` in from the edge is what keeps the approach visible. The
    /// vertical axis follows a ROW THAT DOES NOT MOVE. There is exactly one
    /// moment worth scrolling for — the take is on a row the user cannot see —
    /// and after it there is nothing to chase.
    ///
    /// ⛔⛔ **SO THE RULE IS: SCROLL ONLY WHEN THE ROW IS ENTIRELY OUT OF VIEW,
    /// AND NEVER RE-CENTRE A ROW THAT IS ALREADY VISIBLE.** A performer scrolls
    /// vertically ON PURPOSE — to watch another track while a take runs — and a
    /// vertical follow that re-centred, or that used the horizontal axis'
    /// `edgeMargin`, would drag the view back from wherever they put it. That
    /// fights the user far more visibly than a horizontal page turn ever does,
    /// because a page turn is what they asked for and a yank back to a row they
    /// deliberately scrolled away from is not.
    ///
    /// **"Entirely out" is strict on purpose, and its cost is stated rather than
    /// hidden**: a row showing only a sliver at an edge is left alone. The
    /// conservative direction is the right one here — the failure mode of being
    /// too eager (the view fighting a deliberate scroll) is far worse than the
    /// failure mode of being too shy (a row the user can already partly see is
    /// not moved). It also means a row TALLER than the viewport needs no special
    /// case: it can never be entirely out while any of it is showing.
    ///
    /// ⚠️ **THE TOP CLAMP IS BORROWED FROM m25-b-4, NOT RE-DERIVED.** That item
    /// established that a vertical offset must be clamped at the TOP as well as
    /// floored at 0, **against the NEW content height** — the arrange's row
    /// heights are variable (the S/M/L ladder, plus per-track automation and
    /// take sections), so the ceiling moves. `maxOffset` is the same axis-free
    /// arithmetic the horizontal clamp uses; the argument labels read
    /// `width`/`X` because that shared rule was written on the horizontal axis.
    ///
    /// - Parameters:
    ///   - rowTop: the row's top y in the lanes' CONTENT space.
    ///   - rowHeight: the row's clip-band height (`ArrangeLaneGeometry.rowHeight`).
    ///   - viewportHeight: the visible height of the vertical scroller.
    ///   - contentHeight: the scroller's laid-out content height (the clamp's
    ///     ceiling — measured, never derived from a row count).
    ///   - currentOffset: where the scroller sits right now, reported by the
    ///     view's own geometry.
    public static func rowReveal(rowTop: CGFloat, rowHeight: CGFloat,
                                 viewportHeight: CGFloat, contentHeight: CGFloat,
                                 currentOffset: CGFloat) -> RowReveal? {
        guard viewportHeight > 1, rowHeight > 0 else { return nil }
        let rowBottom = rowTop + rowHeight
        let ceiling = maxOffset(contentWidth: contentHeight, viewportWidth: viewportHeight)
        let target: CGFloat
        let anchorsBottom: Bool
        if rowBottom <= currentOffset {
            target = rowTop                             // entirely ABOVE the viewport
            anchorsBottom = false
        } else if rowTop >= currentOffset + viewportHeight {
            target = rowBottom - viewportHeight         // entirely BELOW it
            anchorsBottom = true
        } else {
            return nil                                  // any part of it is visible
        }
        let clamped = target.clamped(to: 0...max(0, ceiling))
        // The same landing tolerance the page policy uses: a target this close
        // to where the scroller already sits is not worth a scroll. It is what
        // makes the ends of a short session quiet — with the scroller pinned at
        // `maxOffset`, a bottom row's clamped target stops changing.
        if abs(clamped - currentOffset) < landTolerance { return nil }
        return RowReveal(offset: clamped, anchorsBottom: anchorsBottom)
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

    /// The VERTICAL twin of `target(isEnabled:…)` (m34-a-3): the reveal this
    /// surface should perform now, or nil for "stay put".
    ///
    /// ⭐⭐ **IT REUSES THIS MODEL'S SUSPENSION, BASELINE AND COUNTERS RATHER
    /// THAN ADDING A SECOND "WHO OWNS THE SCROLL" POLICY.** The arrange's
    /// vertical scroller is a genuinely different scroller from its horizontal
    /// one (`ScrollView(.vertical)` in `ContentView` vs the lanes' own
    /// `ScrollView(.horizontal)`), which is exactly the "one instance per
    /// scrolling surface" this class documents — so it gets its OWN instance,
    /// and that instance answers the vertical question with the vertical
    /// landing rule. What must never happen is two DIFFERENT suspension rules on
    /// one surface (the m25-r shape); one rule applied to two scrollers is the
    /// opposite of that.
    ///
    /// ⚠️ It deliberately does NOT feed vertical reports into the HORIZONTAL
    /// instance — `PianoRollView.editorVerticalScrollReader` records why: a
    /// second axis' reports arriving at a horizontal detector make every scroll
    /// on the other axis look like a manual horizontal drag.
    ///
    /// `isPlaying` is kept in the signature (and in the guard) for exact parity
    /// with `target`: the two must be able to suspend and re-arm identically, and
    /// a vertical follow that ran while the transport was stopped could move the
    /// view under a user who is editing.
    public func rowRevealTarget(isEnabled: Bool, isPlaying: Bool,
                                rowTop: CGFloat, rowHeight: CGFloat,
                                viewportHeight: CGFloat, contentHeight: CGFloat,
                                currentOffset: CGFloat) -> FollowPlayhead.RowReveal? {
        noteGeometry(contentWidth: contentHeight, viewportWidth: viewportHeight)
        guard isEnabled, isPlaying, !isSuspended else { return nil }
        guard let reveal = FollowPlayhead.rowReveal(
            rowTop: rowTop, rowHeight: rowHeight, viewportHeight: viewportHeight,
            contentHeight: contentHeight, currentOffset: currentOffset) else { return nil }
        expectedOffset = reveal.offset
        issueInFlight = true
        scrollCount += 1
        return reveal
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

    /// Stands follow down on this surface WITHOUT touching the persisted enable
    /// (m23-cu-1) — the same state a manual scroll produces, reached by an
    /// explicit request instead of by a detected divergence.
    ///
    /// Its one caller is the FOLLOW chip while the arrange is following only
    /// because a take is rolling: there the persisted preference is OFF, so a
    /// press cannot be expressed as a toggle of it without meaning the opposite
    /// of what was pressed. ⭐ It reuses `isSuspended` deliberately rather than
    /// adding a second "follow is off right now" flag — two of those on one
    /// surface is the m25-r shape, and `rearm()` already clears this one on the
    /// next transport start, which is exactly the lifetime a per-take stand-down
    /// wants.
    public func standDown() {
        isSuspended = true
        issueInFlight = false
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
