import CoreGraphics

/// Pure geometry for the Explain frame reporter (m25-j) — headless, so the
/// arithmetic that turns a LAYOUT frame into a DRAWN one is testable without a
/// window.
///
/// **The defect it exists to close.** `.explainable` measures its frame with a
/// `GeometryReader` in a `.background`, and a `GeometryReader` can only see
/// LAYOUT. `.offset(x:y:)` is a RENDER-TIME transform: it moves the drawing and
/// leaves the layout where it was. Every timeline clip is placed by exactly that
/// — `.offset(x: startBeat·ppb, y: laneTop(row))` — so before m25-j
/// `debug.explainFrames {ids:["clipBlock"]}` reported the SAME rect for every
/// clip in the arrangement: two clips on different tracks at different beats both
/// read `{x:298, y:163, w:64, h:34}` (MEASURED on staging, 2026-08-23). Widths
/// and heights were right, which is precisely what made it dangerous — the
/// instrument returned a plausible rectangle rather than an error, and a harness
/// that cropped a screenshot at that origin measured an empty neighbouring lane
/// with total confidence (it broke the m25-e visual harness exactly that way).
///
/// **The rule this encodes.** A render offset is only measurable if something
/// TELLS the reporter about it. `offsetExplainable` applies the offset and reports
/// it in ONE call, so the applied value and the reported value are the same value
/// — not two sources kept in step by a comment.
///
/// ⚠️ **SCOPE, MEASURED ON STAGING AND THE OPPOSITE OF THE INTUITIVE READING.**
/// Only the TAGGED VIEW'S OWN offset is missing from the report. An ancestor's
/// `.offset` IS already carried into a descendant's
/// `geo.frame(in: .named(explainRoot))`; what a `.background` GeometryReader
/// cannot see is an offset applied to the very view it hangs off, because
/// `.background` added after `.offset` sits OUTSIDE that offset. The first cut of
/// this fix inherited the offset down an environment key "so descendants are
/// corrected too" — a planted tag inside an offset clip then reported the offset
/// TWICE (`x = 554` where the clip drew at `426`). The inheritance was deleted.
///
/// ⚠️ **The honest limit:** a bare `.offset(...)` applied to a tagged view without
/// going through `offsetExplainable` is still invisible to the reporter.
/// `scripts/gates/m25j-clip-frames.mjs` is the detector — it checks reported
/// origins against independently derived geometry (the app's own `ppb` and the
/// sidebar's own row pitch), so a stray offset shows up as a wrong NUMBER, not
/// merely as a missing one.
public enum ExplainGeometry {
    /// Where a view is actually DRAWN: the layout frame a `GeometryReader`
    /// measured, shifted by the render offset applied to that very view outside
    /// the reader (ancestors' offsets are already in the measurement — see above).
    /// Size is untouched — `.offset` never changes size, which is why widths and
    /// heights were correct throughout the defect.
    public static func drawnFrame(layout: CGRect, renderOffset: CGSize) -> CGRect {
        layout.offsetBy(dx: renderOffset.width, dy: renderOffset.height)
    }
}
