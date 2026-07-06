import CoreGraphics
import Foundation
import DAWCore

/// Quality band of a time-stretch ratio (M5 ii-e). signalsmith-stretch is
/// transparent-ish inside 0.75–1.5×; beyond that it works but smears, so the UI
/// amber-tints the clip as a soft hint (never a hard block —
/// `Clip.stretchRatioRange` still spans 0.25–4).
public enum StretchQualityBand: Sendable, Equatable {
    /// Inside the transparent sweet spot.
    case transparent
    /// Outside 0.75–1.5× — works but smears (amber hint).
    case degraded
}

/// Coarse render state a clip block paints (M5 ii-e), derived from the engine's
/// pull-based `ClipStretchStatus`: an animated shimmer while an offline stretch
/// render is pending, a red error accent on failure, nothing otherwise.
public enum ClipRenderVisual: Sendable, Equatable {
    case none
    case shimmer
    case error
}

/// Headless math + formatting for the arrange stretch handle (M5 ii-e): alt-drag
/// classification, ratio-from-length preview (mirroring `ProjectStore.stretchClip`
/// EXACTLY — window invariance, ratio clamp, and the length re-derivation on
/// clamp), quality-band classification against the 0.75–1.5× sweet spot,
/// badge/readout formatting, and render-state mapping. Static, value-in/value-out
/// — the `ClipBlock` view is thin over these (the `ClipEdit` precedent) and the
/// tests exercise them headless.
public enum ClipStretch {
    /// The transparent sweet spot (from the library-evaluation research doc):
    /// signalsmith is transparent-ish inside this ratio band, degraded outside.
    public static let transparentBand: ClosedRange<Double> = 0.75...1.5

    // MARK: - Gesture classification

    /// True when a right-edge drag should time-stretch rather than trim: the
    /// option key is held AND the clip is audio. MIDI right-edge alt-drag keeps
    /// plain trim (time-stretch is audio-only in v0, the gain/fades family). Any
    /// zone other than the trailing edge is never a stretch.
    public static func isStretchDrag(zone: ClipZone, optionHeld: Bool, isAudio: Bool) -> Bool {
        zone == .trimEnd && optionHeld && isAudio
    }

    // MARK: - Ratio-from-length preview (mirrors ProjectStore.stretchClip)

    /// Target timeline length (beats) for a right-edge stretch drag: the clip's
    /// START stays pinned, the new END snaps to the grid (reusing `ClipSnap` like
    /// a trim), floored so the clip keeps at least `ClipEdit.minClipLengthBeats`.
    public static func targetLength(
        originalStart: Double, originalLength: Double, dragDeltaBeats: Double,
        snap: ClipSnap, beatsPerBar: Int
    ) -> Double {
        let rawEnd = originalStart + originalLength + dragDeltaBeats
        let snapped = snap.snap(beat: max(0, rawEnd), beatsPerBar: beatsPerBar)
        let end = max(snapped, originalStart + ClipEdit.minClipLengthBeats)
        return end - originalStart
    }

    /// Resulting `(length, ratio)` a stretch to `targetLength` produces, EXACTLY
    /// mirroring `ProjectStore.stretchClip`: it holds the source window invariant
    /// (`length / ratio` constant), scales the ratio by the length change and
    /// clamps it to `Clip.stretchRatioRange`, and ON CLAMP re-derives the length
    /// from the (constant) invariant so the on-screen preview never disagrees with
    /// what the store persists. A degenerate zero-length / zero-ratio clip falls
    /// back to a plain length set at the current ratio (the store's guard).
    public static func stretchPreview(
        oldLength: Double, oldRatio: Double, targetLength: Double
    ) -> (length: Double, ratio: Double) {
        let target = max(ClipEdit.minClipLengthBeats, targetLength)
        guard oldLength > 0, oldRatio > 0 else { return (target, oldRatio) }
        let windowInvariant = oldLength / oldRatio          // == length / ratio
        let desiredRatio = oldRatio * (target / oldLength)
        let newRatio = desiredRatio.clamped(to: Clip.stretchRatioRange)
        let newLength = newRatio == desiredRatio
            ? target
            : max(ClipEdit.minClipLengthBeats, windowInvariant * newRatio)
        return (newLength, newRatio)
    }

    // MARK: - Quality band

    /// Classifies a ratio against the transparent sweet spot.
    public static func qualityBand(ratio: Double) -> StretchQualityBand {
        transparentBand.contains(ratio) ? .transparent : .degraded
    }

    /// A clip is out-of-band (amber hint) only when it is actually stretched
    /// (ratio != 1) and the ratio sits outside the transparent 0.75–1.5× range.
    /// An identity clip (ratio 1) is never flagged.
    public static func isOutOfBand(ratio: Double) -> Bool {
        ratio != 1 && qualityBand(ratio: ratio) == .degraded
    }

    // MARK: - Formatting

    /// Ratio readout: two decimals + "×", e.g. 1.5 → "1.50×", 0.75 → "0.75×".
    public static func ratioString(_ ratio: Double) -> String {
        String(format: "%.2f×", ratio)
    }

    /// Signed semitone readout, e.g. +3 → "+3st", -5 → "-5st", +3.5 → "+3.5st".
    /// Whole values drop the decimal; the sign is always explicit (callers only
    /// format non-zero shifts).
    public static func semitoneString(_ semitones: Double) -> String {
        let rounded = (semitones * 10).rounded() / 10
        let whole = rounded == rounded.rounded()
        let mag = whole ? String(format: "%+.0f", rounded) : String(format: "%+.1f", rounded)
        return mag + "st"
    }

    /// Persistent badge for a non-identity clip (ratio != 1 and/or a pitch
    /// shift): `"1.50×"`, `"+3st"`, or `"1.50× +3st"`. `nil` for a structural
    /// identity clip so unstretched clips carry no badge.
    public static func badge(ratio: Double, semitones: Double) -> String? {
        var parts: [String] = []
        if ratio != 1 { parts.append(ratioString(ratio)) }
        if semitones != 0 { parts.append(semitoneString(semitones)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Live drag readout for the stretch handle: `"6.0 beats · 1.50×"` (target
    /// length at one decimal, then the resulting ratio).
    public static func stretchReadout(length: Double, ratio: Double) -> String {
        String(format: "%.1f beats · ", length) + ratioString(ratio)
    }

    /// Tooltip line for an out-of-band clip: names the ratio and the transparent
    /// range so a beginner understands the amber hint (docs/DESIGN-LANGUAGE.md
    /// rule 6). Callers gate this on `isOutOfBand`.
    public static func outOfBandHelp(ratio: Double) -> String {
        "Stretched " + ratioString(ratio)
            + " — outside the 0.75–1.5× transparent range; quality may smear"
    }

    // MARK: - Render state

    /// Maps the engine's pull-based stretch status to the coarse visual the clip
    /// block paints. `nil`/`.idle` → nothing; `.rendering` → shimmer; `.failed`
    /// → error accent.
    public static func renderVisual(for status: ClipStretchStatus?) -> ClipRenderVisual {
        switch status {
        case .rendering: return .shimmer
        case .failed: return .error
        case .idle, nil: return .none
        }
    }
}
