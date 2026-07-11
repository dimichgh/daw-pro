import CoreGraphics
import Foundation
import DAWCore

/// Pitch↔y and beat↔x mapping for a MIDI clip's mini note map (beta m10-f): given
/// a clip's notes, its length, the timeline's fixed pixels-per-beat, and a draw
/// height, it produces the rounded-pill rect for every note so the arrange clip
/// block (and the dim take-lane strip) can show WHERE the sound sits instead of
/// reading blank. A value type carrying only geometry — pure, `Equatable`,
/// headless-testable (the `TakeLaneGeometry` / `ClipEditGeometry` precedent).
///
/// Mapping: notes span `[lo, hi]` pitch, clamped to a height of at least 1 so a
/// single-pitch clip never divides by zero (it maps to the bottom, the take-lane
/// idiom — a single pitch has no vertical span to show). Higher pitch sits nearer
/// the top (docs/DESIGN-LANGUAGE.md: pitch rows high-at-top). x is the note's beat
/// offset times `pixelsPerBeat`; a note is clamped to the clip's right edge and a
/// very short note keeps `minPillWidth` so it stays visible. This is the SAME
/// geometry the take-lane note strip uses, so the two renderings never drift.
public struct MIDIMapGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat`.
    public var pixelsPerBeat: CGFloat
    /// Clear space kept at the top AND bottom edge so pills don't touch the border.
    public var verticalInset: CGFloat
    /// Thickness of each note pill (its drawn height).
    public var pillHeight: CGFloat
    /// Smallest drawn width so a very short note is still a visible pill.
    public var minPillWidth: CGFloat

    public init(pixelsPerBeat: CGFloat = 16,
                verticalInset: CGFloat = 3,
                pillHeight: CGFloat = 3,
                minPillWidth: CGFloat = 2) {
        self.pixelsPerBeat = pixelsPerBeat
        self.verticalInset = verticalInset
        self.pillHeight = pillHeight
        self.minPillWidth = minPillWidth
    }

    /// The `[lo, hi]` pitch span the notes occupy, or nil for empty notes (nothing
    /// to draw). A single pitch returns `lo == hi`; callers clamp the divisor.
    public static func pitchSpan(_ notes: [MIDINote]) -> (lo: Int, hi: Int)? {
        guard let first = notes.first else { return nil }
        var lo = first.pitch
        var hi = first.pitch
        for note in notes {
            lo = Swift.min(lo, note.pitch)
            hi = Swift.max(hi, note.pitch)
        }
        return (lo, hi)
    }

    /// Vertical fraction (0 = bottom, 1 = top) for a `pitch` within `[lo, hi]`.
    /// A single-pitch span (lo == hi) clamps the divisor to 1, so every note reads
    /// as frac 0 (the bottom) — the take-lane idiom for a clip with no pitch span.
    public static func pitchFraction(_ pitch: Int, lo: Int, hi: Int) -> Double {
        let span = Swift.max(1, hi - lo)
        return Double(pitch - lo) / Double(span)
    }

    /// The pill rect for one note within a clip of `clipLengthBeats`, drawn into a
    /// box of `height`, given the note's pitch span `[lo, hi]`. Higher pitch sits
    /// nearer the top; the pill is clamped to the clip's right edge; nil when the
    /// note starts at or after the clip's end (it has no visible extent).
    public func rect(for note: MIDINote, lo: Int, hi: Int,
                     clipLengthBeats: Double, height: CGFloat) -> CGRect? {
        let contentWidth = Swift.max(0, CGFloat(clipLengthBeats) * pixelsPerBeat)
        let x = Swift.max(0, CGFloat(note.startBeat) * pixelsPerBeat)
        guard x < contentWidth else { return nil }
        let rawWidth = Swift.max(minPillWidth, CGFloat(note.lengthBeats) * pixelsPerBeat)
        let width = Swift.min(rawWidth, contentWidth - x)   // clamp to the clip's right edge
        let usableHeight = Swift.max(0, height - verticalInset * 2)
        let frac = Self.pitchFraction(note.pitch, lo: lo, hi: hi)
        let centerY = height - verticalInset - CGFloat(frac) * usableHeight
        return CGRect(x: x, y: centerY - pillHeight / 2, width: width, height: pillHeight)
    }

    /// Every note's pill rect, in note order (empty for no notes). The pitch span
    /// is computed once across all notes, so the whole clip shares one vertical
    /// scale. Notes that start past the clip end are dropped (no visible extent).
    public func noteRects(_ notes: [MIDINote], clipLengthBeats: Double, height: CGFloat) -> [CGRect] {
        guard let (lo, hi) = Self.pitchSpan(notes) else { return [] }
        var rects: [CGRect] = []
        rects.reserveCapacity(notes.count)
        for note in notes {
            if let r = rect(for: note, lo: lo, hi: hi,
                            clipLengthBeats: clipLengthBeats, height: height) {
                rects.append(r)
            }
        }
        return rects
    }
}
