import CoreGraphics

/// Pure timeline↔clip-local mapping for the piano-roll transport playhead and its
/// free scrub (beta m10-e). The editor works in CLIP-LOCAL beats while the
/// transport reports a PROJECT-timeline position; this namespace bridges the two
/// given the edited clip's start on the timeline, so the SwiftUI view stays thin
/// and the mapping unit-tests headless (the `ClipEdit`/`ClipStretch` precedent).
///
/// The playhead is a RENDERING of existing transport state — no new engine tick
/// (the view consumes the SAME `positionBeats` the arrange timeline does) and no
/// new wire command: seeking already exists on the wire as `transport.seek`, and
/// the scrub calls the app's store seek with a clamped project beat.
public enum PianoRollPlayhead {

    /// Clip-local beat of a project-timeline `position`. May be negative (the
    /// transport sits before the clip) or greater than `lengthBeats` (after it) —
    /// callers gate drawing with `isVisible`.
    public static func localBeat(position: Double, clipStartBeat: Double) -> Double {
        position - clipStartBeat
    }

    /// True when the transport position falls WITHIN the clip's span on the
    /// timeline (clip-local `0…lengthBeats`, both edges inclusive). The
    /// honest-absence rule: the line draws ONLY here — never parked at an edge
    /// when the transport is elsewhere. Inclusive edges so the line shows at the
    /// clip's exact start and its exact end.
    public static func isVisible(position: Double, clipStartBeat: Double,
                                 lengthBeats: Double) -> Bool {
        let local = localBeat(position: position, clipStartBeat: clipStartBeat)
        return local >= 0 && local <= lengthBeats
    }

    /// Content-space x for the playhead line, or nil when the transport is
    /// outside the clip (no line drawn). `x = (position − clipStartBeat) · pixelsPerBeat`
    /// — the same beat→pixel form the arrange playhead uses, one clip-offset in.
    public static func lineX(position: Double, clipStartBeat: Double,
                             lengthBeats: Double, pixelsPerBeat: CGFloat) -> CGFloat? {
        guard isVisible(position: position, clipStartBeat: clipStartBeat,
                        lengthBeats: lengthBeats) else { return nil }
        return CGFloat(localBeat(position: position, clipStartBeat: clipStartBeat)) * pixelsPerBeat
    }

    /// Project-timeline beat a scrub at content `localX` targets. Free — UNSNAPPED,
    /// the deliberate pro default (see docs/DESIGN-LANGUAGE.md): local x → clip-local
    /// beat, clamped to the clip span `0…lengthBeats`, then offset back onto the
    /// timeline by `clipStartBeat`. Clamping at BOTH ends keeps a seek inside the
    /// edited clip so a scrub never leaves the editor's span.
    public static func scrubProjectBeat(localX: CGFloat, clipStartBeat: Double,
                                        lengthBeats: Double, pixelsPerBeat: CGFloat) -> Double {
        let rawLocal = pixelsPerBeat > 0 ? Double(localX) / Double(pixelsPerBeat) : 0
        let clampedLocal = min(max(0, rawLocal), max(0, lengthBeats))
        return clipStartBeat + clampedLocal
    }
}
