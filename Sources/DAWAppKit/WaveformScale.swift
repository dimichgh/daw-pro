import CoreGraphics
import Foundation

/// Headless drawing-scale math for the arrange waveform (m25-e): the auto-fit
/// normalisation factor, its boost CAP, the vertical-zoom ladder, and the two
/// readout labels. Pure functions + constants so every rule is unit-testable
/// without SwiftUI (the `ArrangeZoom` precedent — that type owns the HORIZONTAL
/// scale's math, this one owns the VERTICAL).
///
/// The LIVE values are persisted app-side as sticky PREFERENCES in
/// `PanelLayoutStore.waveformNormalize` / `.waveformVerticalZoom` (the
/// `arrangePPB` slot's siblings — never project data, never undoable, never in
/// the wire snapshot); this type owns only the math.
///
/// ## Why normalisation is a MODE and not a silent global change
///
/// Before m25-e the clip waveform drew RAW peak amplitude straight onto half the
/// clip height, so material mastered to a quiet peak drew as a thin ribbon in a
/// mostly-empty block. Fitting it to the clip is the obvious fix and it is the
/// default — but scaling each file to its own peak DESTROYS the at-a-glance
/// comparison between clips ("that one is hotter than this one"), which is real
/// mixing signal. So `normalize` is a switch the user can turn off to get the
/// true amplitude picture back, and the boost is capped so a near-silent clip
/// still READS as near-silent rather than exploding into full-height noise.
public enum WaveformScale {

    // MARK: - Auto-fit normalisation

    /// Auto-fit starts ON. The `auditionEnabled` rationale, not the
    /// `followPlayhead` one: the user's complaint IS the un-normalised look, so
    /// the fix has to be visible without hunting for a switch. The switch exists
    /// as the escape hatch back to true amplitude, not as an opt-in that would
    /// leave the feature invisible by default.
    public static let defaultNormalize = true

    /// The most a fit may boost a clip: **4× (+12 decibels of drawn height)**.
    ///
    /// Chosen against what the material actually looks like:
    /// - A finished master peaks near full scale → factor ≈ 1, drawn unchanged.
    /// - A mixed stem or a tracked take usually peaks between a half and a
    ///   quarter of full scale → factor 2–4, which fills the clip. **This is the
    ///   case the user complained about, and it is fully covered by the cap.**
    /// - Anything quieter than a quarter of full scale is GENUINELY quiet — a
    ///   soft passage, a fade tail, room tone — and stays visibly short: at the
    ///   cap a peak one hundredth of full scale still draws at 4 % of the
    ///   half-height, i.e. it still reads as near-silence. Without a cap it would
    ///   fill the clip and a noise floor would look like a performance.
    ///
    /// **The cost, stated rather than hidden:** at this cap every clip peaking at
    /// or above a quarter of full scale draws to full height, so in fit mode two
    /// clips a few units apart up there are indistinguishable. That loss is
    /// exactly why `normalize` is a mode and why `RAW` is one click away.
    public static let maxNormalizeBoost: CGFloat = 4

    /// The fit factor for a source whose loudest peak is `peakMax` (0…1, the
    /// value `WaveformPeaks.peakMax` carries).
    ///
    /// Returns 1 when `normalize` is off, when the peak is already full scale, or
    /// when the source is all-silence (`peakMax <= 0` — the divide-by-zero guard;
    /// a silent file has no shape to fit, and boosting nothing yields nothing).
    /// Never exceeds `maxNormalizeBoost`, and never REDUCES: a hot file is drawn
    /// at its true height, never squashed.
    public static func normalizeGain(peakMax: Float, normalize: Bool) -> CGFloat {
        guard normalize, peakMax > 0 else { return 1 }
        return min(maxNormalizeBoost, max(1, 1 / CGFloat(peakMax)))
    }

    // MARK: - Vertical zoom

    /// No extra magnification — the ⌥⌘0 reset target.
    public static let defaultVerticalZoom: CGFloat = 1

    /// Clamp bounds. The floor is 1 because zooming a waveform SMALLER is the
    /// complaint this item exists to fix, not a feature; 8× is well past the
    /// point where a quiet passage's shape reads, and the drawing clips at the
    /// clip rect long before it (standard DAW behaviour).
    public static let verticalZoomRange: ClosedRange<CGFloat> = 1...8

    /// The discrete rungs the ± steppers and the chip menu walk. A LADDER rather
    /// than `ArrangeZoom`'s multiplicative `stepFactor`, because this readout is
    /// short and permanent: a 1.25× ladder would show `1.6×`, `1.9×`, `2.4×` and
    /// make a two-character chip unreadable. A wire- or drag-set value between
    /// rungs is legal (the store clamps, it does not snap); stepping from it
    /// moves to the next rung in that direction.
    public static let zoomLadder: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8]

    /// Tames any requested magnification into the legal range.
    public static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        zoom.clamped(to: verticalZoomRange)
    }

    /// One rung up (⌥⌘+ / the chip's "+"). From a between-rungs value this lands
    /// on the next rung ABOVE it; at the top it stays put.
    public static func zoomedIn(_ zoom: CGFloat) -> CGFloat {
        let current = clampZoom(zoom)
        // A hair of tolerance so a rung that arrived as a Double round-trip
        // (`2.0000000000000004`) still counts as ITSELF and steps to the next one.
        return clampZoom(zoomLadder.first { $0 > current + 0.0001 } ?? current)
    }

    /// One rung down (⌥⌘− / the chip's "−"). From a between-rungs value this
    /// lands on the next rung BELOW it; at the bottom it stays put.
    public static func zoomedOut(_ zoom: CGFloat) -> CGFloat {
        let current = clampZoom(zoom)
        return clampZoom(zoomLadder.last { $0 < current - 0.0001 } ?? current)
    }

    // MARK: - The drawn scale (what the Canvas multiplies by)

    /// The factor a clip's stored 0…1 magnitudes are multiplied by before they
    /// are mapped onto the clip's half-height: the fit gain and the user's
    /// magnification, composed. The ONE function the drawing layer calls.
    public static func drawScale(peakMax: Float, normalize: Bool,
                                 verticalZoom: CGFloat) -> CGFloat {
        normalizeGain(peakMax: peakMax, normalize: normalize) * clampZoom(verticalZoom)
    }

    // MARK: - Readouts (SF Mono, docs/DESIGN-LANGUAGE.md)

    /// The magnification alone, e.g. `1×`, `1.5×`, `4×`. Halves keep one decimal,
    /// whole numbers drop it — the chip is 3 glyphs wide at most.
    public static func zoomLabel(_ zoom: CGFloat) -> String {
        let z = clampZoom(zoom)
        let rounded = (z * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))×"
        }
        return String(format: "%.1f×", Double(rounded))
    }

    /// The chip's whole state in one short SF Mono string: the mode, plus the
    /// magnification only when it is doing something. `FIT`, `RAW`, `FIT 2×`,
    /// `RAW 1.5×` — so the chip never claims a zoom it isn't applying.
    public static func modeLabel(normalize: Bool, verticalZoom: CGFloat) -> String {
        let mode = normalize ? "FIT" : "RAW"
        let z = clampZoom(verticalZoom)
        guard abs(z - defaultVerticalZoom) > 0.0001 else { return mode }
        return mode + " " + zoomLabel(z)
    }

    /// One-line plain-language description of what the surface is doing right
    /// now — the chip's tooltip and the menu's footer, so the mode explains
    /// itself in place (docs/DESIGN-LANGUAGE.md: beginner-readable labels).
    public static func help(normalize: Bool, verticalZoom: CGFloat) -> String {
        let base = normalize
            ? "Waveforms are scaled up to fill the clip, so quiet parts still show their shape."
            : "Waveforms are drawn at their true level, so you can see which clips are louder."
        let z = clampZoom(verticalZoom)
        guard abs(z - defaultVerticalZoom) > 0.0001 else { return base }
        return base + " Magnified \(zoomLabel(z)); taller peaks are trimmed at the clip edge."
    }
}
