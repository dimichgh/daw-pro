import CoreGraphics
import Foundation

/// THE ONE HOME for the flip/edge arithmetic that expresses an AppKit rect in the
/// row space of a rasterized capture (m23-ag).
///
/// A window's content view may be flipped (top-left origin, the orientation a PNG's
/// rows are in) or unflipped (bottom-left origin, AppKit's default). `debug.captureUI`
/// rasterizes that content view, so a rect measured against it has to be re-expressed
/// top-left before a caller can turn it into an image row — and getting that branch
/// wrong is invisible: it produces a plausible number that points at the wrong rows.
/// One formula, one place, headless-testable, so the app-side probe cannot grow a
/// second, divergent version of it.
public enum CaptureSpaceGeometry {
    /// `rect`'s origin re-expressed top-left, i.e. in the same orientation as the
    /// captured image's rows.
    ///
    /// - Parameters:
    ///   - rect: a rect already converted into the content view's coordinates.
    ///   - contentHeight: `contentView.bounds.height`, in POINTS.
    ///   - isFlipped: `contentView.isFlipped` — branch on it, never assume it. When
    ///     flipped the content view is ALREADY top-left, so the top edge is
    ///     `rect.minY`; when it is not, the top edge is `contentHeight - rect.maxY`.
    /// - Returns: the top-left origin, in points, of `rect` in image-row space.
    ///
    /// Assumes `contentView.bounds.origin == .zero` (true for every window content
    /// view AppKit hands us; a bounds-shifted content view would need the origin
    /// subtracted as well, and the caller reports the raw `bounds` rect alongside so
    /// a consumer can see that it was zero).
    public static func topLeftOrigin(of rect: CGRect,
                                     contentHeight: CGFloat,
                                     isFlipped: Bool) -> CGPoint {
        CGPoint(x: rect.minX,
                y: isFlipped ? rect.minY : contentHeight - rect.maxY)
    }
}
