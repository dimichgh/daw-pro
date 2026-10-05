import CoreGraphics
import Foundation
import DAWCore

/// **m35-h — where the pitch axis should sit when the roll OPENS on a clip.**
///
/// THE DEFECT THIS EXISTS FOR: the roll opens on `.defaultScrollAnchor(.center)`,
/// i.e. near middle C in the 128-row stack. A clip written low — a 49 Hz sub at
/// C1 (MIDI 24), an 808 at F1 — therefore opens on an **EMPTY GRID**: the notes
/// are real, drawn in the minimap and in the velocity lane, and simply below the
/// viewport. ⚠️ Row height is NOT the workaround: MEASURED at the 10 pt floor
/// (`PanelLayoutStore.pianoRollRowHeightRange` is `10...56`, so a request for 5
/// lands at 10) the grid still bottomed out at F2 with the notes below it —
/// shrinking rows fits more keys and keeps the same anchor.
///
/// This type is the POLICY only. The scroll seam already exists
/// (`PianoRollView.focusPitchAxis(on:)`, driven over the wire today by
/// `debug.panelLayout {pianoRollCenterPitch}`); everything here is pure integer
/// geometry so the decision is headless-testable and the view stays thin.
public enum PianoRollOpenFocus {
    /// The rows a user can actually SEE and read — both edges inside the visible
    /// box, with the frozen scrub strip's `topInset` already taken off the top.
    ///
    /// ⚠️ **DELIBERATELY NOT `PianoRollView.visiblePitchWindow`, and the reason is
    /// the direction of its error.** That window is measured against the raw
    /// scroller height, which its own doc says overstates the visible pitch by the
    /// ~18 pt frozen scrub strip — safe for the paste nudge it bounds (it never
    /// claims the window is SMALLER than it is). Here the safe direction is the
    /// opposite one: a note whose row hides under the strip counted as "in frame"
    /// would suppress the scroll and leave the user looking at an invisible note,
    /// which is the very bug. So this one is strict — top inset subtracted, and
    /// PARTIAL rows at either edge excluded.
    ///
    /// Row geometry is `PianoRollModel`'s: row of pitch `p` occupies
    /// `[(127 − p)·rowHeight, (128 − p)·rowHeight]`, so y grows as pitch falls.
    ///
    /// - Returns: the fully-visible pitch range, or `nil` when the box is not yet
    ///   laid out or cannot fit one whole row.
    public static func visiblePitchWindow(scrollY: CGFloat,
                                          viewportHeight: CGFloat,
                                          topInset: CGFloat,
                                          rowHeight: CGFloat) -> ClosedRange<Int>? {
        guard rowHeight > 0, viewportHeight > 0 else { return nil }
        let top = scrollY + max(0, topInset)
        let bottom = scrollY + viewportHeight
        guard bottom - top >= rowHeight else { return nil }
        let lastRow = PianoRollModel.pitchCount - 1
        // Highest fully-visible pitch: the first row whose TOP edge is at or below
        // the (inset) viewport top.
        let highest = lastRow - Int((top / rowHeight).rounded(.up))
        // Lowest fully-visible pitch: the last row whose BOTTOM edge is at or above
        // the viewport bottom.
        let lowest = lastRow + 1 - Int((bottom / rowHeight).rounded(.down))
        let hi = highest.clamped(to: 0...lastRow)
        let lo = lowest.clamped(to: 0...lastRow)
        guard lo <= hi else { return nil }
        return lo...hi
    }

    /// The pitch the roll should centre on when it opens, or `nil` to leave the
    /// anchor exactly where it is.
    ///
    /// **THE RULES, and why each is what it is.**
    ///
    /// **EMPTY CLIP → `nil`.** There is no range to centre on, so the default
    /// `.center` anchor (near middle C) stands. Stated here rather than left to
    /// fall out of the code: an empty clip is the one case where the roll's
    /// existing behaviour is already the right one — the user is about to draw,
    /// and middle C is where a keyboard player expects to start.
    ///
    /// **ALREADY IN FRAME → `nil`.** It must never fight a user who scrolled
    /// deliberately, and must not yank a clip that was already fine.
    ///
    /// **RANGE THAT FITS → the MIDPOINT of `lo...hi`.** When the span fits the
    /// viewport, centring the midpoint puts EVERY note on screen — a guarantee the
    /// median cannot make (a median sitting near one end of a fitting range can
    /// still push the other end out).
    ///
    /// **RANGE THAT DOES NOT FIT → the MEDIAN NOTE PITCH.** A clip spanning C1 to
    /// C6 cannot fit at any row height in the ladder, so *something* is going to be
    /// off screen and the only question is what. The midpoint is the wrong answer
    /// here: for a bass line at C1 with four ornaments at C6 the midpoint is ~C3.5,
    /// a region containing NO NOTES AT ALL — the blank-grid bug reproduced by the
    /// fix meant to cure it. The median is an ACTUAL ELEMENT of the note list
    /// (`sorted[n / 2]`, never the average of two), so centring on it puts a real
    /// note on the centre row: the grid is never blank, and the viewport lands
    /// where the music's mass is.
    ///
    /// ⚠️ The consequence is deliberate: a wide clip showing 4 of its 40 notes at
    /// the default anchor WILL move on open. "Already fine" means the music is in
    /// frame, not that some pixel of it is.
    ///
    /// - Parameters:
    ///   - notePitches: every note in the clip (order irrelevant, duplicates count
    ///     — they are what weights the median toward the dense region).
    ///   - visible: the strict window from `visiblePitchWindow`. `nil` (not laid
    ///     out) yields `nil`: with no window there is no in-frame test to run, and
    ///     scrolling on a guess is how a correct policy lands at the wrong cadence.
    public static func focusPitch(notePitches: [Int],
                                  visible: ClosedRange<Int>?) -> Int? {
        guard let visible, !notePitches.isEmpty else { return nil }
        let sorted = notePitches.sorted()
        let lo = sorted[0]
        let hi = sorted[sorted.count - 1]
        let span = hi - lo + 1
        if span <= visible.count {
            guard !(visible.contains(lo) && visible.contains(hi)) else { return nil }
            return (lo + hi) / 2
        }
        let median = sorted[sorted.count / 2]
        return visible.contains(median) ? nil : median
    }
}
