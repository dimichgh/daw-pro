import CoreGraphics
import Foundation
import DAWCore

/// Grid snap resolution for the arrange clip editor (M5 i-d), expressed as a
/// beat division. `bar` respects the project time signature (`beatsPerBar`);
/// `beat` = 1 beat, `half` = 1/2 beat, `quarter` = 1/4 beat, `off` disables
/// snapping. Distinct from the piano roll's `SnapResolution` (which hard-codes a
/// 4-beat bar and names fine grids musically): the clip surface snaps clip
/// MOVE / TRIM / SPLIT to a beat grid that follows the meter, so a 3/4 session
/// snaps bars every 3 beats. Labels are beginner-first for the coarse divisions
/// and plain fractions for the fine ones (docs/DESIGN-LANGUAGE.md rule 6).
public enum ClipSnap: String, CaseIterable, Sendable, Equatable {
    case off
    case bar
    case beat
    case half
    case quarter

    /// Grid size in beats for the given meter, or nil when snapping is off. Only
    /// `bar` depends on the time signature; the finer divisions are meter-agnostic.
    public func gridBeats(beatsPerBar: Int) -> Double? {
        switch self {
        case .off: return nil
        case .bar: return Double(max(1, beatsPerBar))
        case .beat: return 1
        case .half: return 0.5
        case .quarter: return 0.25
        }
    }

    /// Chip / menu label.
    public var label: String {
        switch self {
        case .off: return "Off"
        case .bar: return "Bar"
        case .beat: return "Beat"
        case .half: return "1/2"
        case .quarter: return "1/4"
        }
    }

    /// Snaps `beat` to the nearest grid line for the given meter (>= 0). `off`
    /// passes the value through, still floored at 0.
    public func snap(beat: Double, beatsPerBar: Int) -> Double {
        guard let grid = gridBeats(beatsPerBar: beatsPerBar), grid > 0 else { return max(0, beat) }
        return max(0, (beat / grid).rounded() * grid)
    }

    /// Meter-map-aware snap (m12-d, design rows 62–67). `bar` follows the
    /// accumulated meter — across a time-signature change the bar grid is not
    /// uniform, so it routes through `MeterMap.nearestBarline`; the finer
    /// divisions (`beat`/`half`/`quarter`) are meter-agnostic (a beat is a
    /// quarter-note everywhere) and fall through to the uniform math. Reproduces
    /// `snap(beat:beatsPerBar:)` exactly for a trivial single-meter map, so
    /// arrange surfaces adopt it without changing single-meter behavior.
    public func snap(beat: Double, meterMap: MeterMap) -> Double {
        switch self {
        case .bar: return max(0, meterMap.nearestBarline(toBeat: max(0, beat)))
        default: return snap(beat: beat, beatsPerBar: meterMap.beatsPerBar(atBeat: max(0, beat)))
        }
    }

    /// The snap the arrange clip lane actually uses for a given panel density
    /// (docs/DESIGN-LANGUAGE.md "Panels", sp-c). **Simple locks the grid to `.bar`**
    /// — a beginner moves clips a whole bar at a time and the snap picker is hidden
    /// — mirroring the piano roll locking Simple to whole beats. Pro honors the
    /// `picked` resolution. This never mutates `picked`, so flipping back to Pro
    /// restores the user's choice. Pure, so the view layer is a thin conditional
    /// over a tested contract.
    public static func effective(density: PanelDensity, picked: ClipSnap) -> ClipSnap {
        density == .pro ? picked : .bar
    }
}

/// Which part of a clip block a point landed on — routes a press to the right
/// edit (fade a corner, trim an edge, or move the body).
public enum ClipZone: Sendable, Equatable {
    case fadeInHandle
    case fadeOutHandle
    case trimStart
    case trimEnd
    case body
}

/// Beat↔x mapping and clip-local hit classification for one arrange clip block,
/// aligned to the timeline's fixed pixels-per-beat so trim/split math lines up
/// with the grid. A value type carrying only geometry — pure, `Equatable`,
/// headless-testable (the `AutomationGeometry` precedent). Coordinates are
/// CLIP-LOCAL: x = 0 at the clip's left edge, y = 0 at its top; the caller has
/// already offset the block by `startBeat * pixelsPerBeat`.
public struct ClipEditGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat`.
    public var pixelsPerBeat: CGFloat
    /// Clip lane height.
    public var laneHeight: CGFloat
    /// Edge grab strip (points) at the left/right for trim.
    public var edgeHitWidth: CGFloat
    /// How far down from the top a fade grip stays grabbable.
    public var fadeHandleZoneHeight: CGFloat
    /// Grab radius (points) around a fade grip.
    public var fadeHandleHitRadius: CGFloat

    public init(
        pixelsPerBeat: CGFloat = 16,
        laneHeight: CGFloat = 34,
        edgeHitWidth: CGFloat = 6,
        fadeHandleZoneHeight: CGFloat = 12,
        fadeHandleHitRadius: CGFloat = 9
    ) {
        self.pixelsPerBeat = pixelsPerBeat
        self.laneHeight = laneHeight
        self.edgeHitWidth = edgeHitWidth
        self.fadeHandleZoneHeight = fadeHandleZoneHeight
        self.fadeHandleHitRadius = fadeHandleHitRadius
    }

    /// x for a clip-local beat offset (beats measured from the clip start).
    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    /// Clip-local beat offset at an x, floored at 0.
    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    /// Local x of the fade-in grip (the fade-in's inner end), clamped to the block.
    public func fadeInHandleX(fadeInBeats: Double, clipWidth: CGFloat) -> CGFloat {
        min(max(CGFloat(fadeInBeats) * pixelsPerBeat, 0), clipWidth)
    }

    /// Local x of the fade-out grip (the fade-out's inner start), clamped.
    public func fadeOutHandleX(fadeOutBeats: Double, clipWidth: CGFloat) -> CGFloat {
        min(max(clipWidth - CGFloat(fadeOutBeats) * pixelsPerBeat, 0), clipWidth)
    }

    /// Classifies a clip-local point. Precedence: a fade grip in the top zone
    /// wins over the edge strip beneath it (so the top corners fade and the rest
    /// of the edge trims — the Logic idiom), then edges, then the body.
    public func classifyZone(
        localPoint p: CGPoint, clipWidth w: CGFloat,
        fadeInBeats: Double, fadeOutBeats: Double
    ) -> ClipZone {
        let fiX = fadeInHandleX(fadeInBeats: fadeInBeats, clipWidth: w)
        let foX = fadeOutHandleX(fadeOutBeats: fadeOutBeats, clipWidth: w)
        if p.y <= fadeHandleZoneHeight {
            let dIn = abs(p.x - fiX)
            let dOut = abs(p.x - foX)
            if dIn <= fadeHandleHitRadius, dIn <= dOut { return .fadeInHandle }
            if dOut <= fadeHandleHitRadius { return .fadeOutHandle }
        }
        if p.x <= edgeHitWidth { return .trimStart }
        if p.x >= w - edgeHitWidth { return .trimEnd }
        return .body
    }
}

/// Pure clip-edit math for the arrange gesture layer: snapped move/trim/split
/// preview, fade-handle length preview, and gain formatting. Every op mirrors the
/// store's clamping rules (min clip length 1/32 beat, fade sum <= length, gain
/// range) so the on-screen preview never disagrees with what the five
/// `ProjectStore` methods will persist. Static, value-in/value-out — the view is
/// thin over these and the tests exercise them headless.
public enum ClipEdit {
    /// Floor on a trimmed clip's length — mirrors `ProjectStore.minClipLengthBeats`
    /// (1/32 of a beat) so a trim preview can never go past what the store allows.
    public static let minClipLengthBeats: Double = 1.0 / 32.0

    // MARK: - Move

    /// New (snapped, floored) start beat for a body drag: the original start plus
    /// the raw beat delta, snapped to the grid. Feeds `moveClip(toStartBeat:)`.
    /// Meter-aware (m13-h): a drag INTO a different time-signature region snaps on
    /// that region's grid — `.bar` routes through `MeterMap.nearestBarline`, so a
    /// clip pulled into a 6/8 section lands on the 6/8 barlines. Reproduces the
    /// old base-meter math exactly for a trivial single-meter map.
    public static func movedStartBeat(
        originalStart: Double, dragDeltaBeats: Double,
        snap: ClipSnap, meterMap: MeterMap
    ) -> Double {
        snap.snap(beat: max(0, originalStart + dragDeltaBeats), meterMap: meterMap)
    }

    // MARK: - Trim

    /// New `(startBeat, lengthBeats)` for a leading-edge (start) trim. The clip's
    /// END stays pinned; the new start snaps, floors at 0, and is capped so the
    /// clip keeps at least `minClipLengthBeats`. Feeds `trimClip(...)`.
    public static func trimStart(
        originalStart: Double, originalLength: Double, newStartBeatRaw: Double,
        snap: ClipSnap, meterMap: MeterMap
    ) -> (startBeat: Double, lengthBeats: Double) {
        let end = originalStart + originalLength
        let snapped = snap.snap(beat: max(0, newStartBeatRaw), meterMap: meterMap)
        let maxStart = max(0, end - minClipLengthBeats)
        let start = min(max(0, snapped), maxStart)
        return (start, end - start)
    }

    /// New `(startBeat, lengthBeats)` for a trailing-edge (end) trim. The clip's
    /// START stays pinned; the new end snaps and is floored so the clip keeps at
    /// least `minClipLengthBeats`. Feeds `trimClip(...)`.
    public static func trimEnd(
        originalStart: Double, newEndBeatRaw: Double,
        snap: ClipSnap, meterMap: MeterMap
    ) -> (startBeat: Double, lengthBeats: Double) {
        let snapped = snap.snap(beat: max(0, newEndBeatRaw), meterMap: meterMap)
        let end = max(snapped, originalStart + minClipLengthBeats)
        return (originalStart, end - originalStart)
    }

    // MARK: - Fades (not snapped — a fade is a continuous shape)

    /// Fade-in length (beats) for a grip dragged to clip-local `x`, clamped to
    /// `[0, length - fadeOut]` so the two fades never overlap (matching the
    /// store's proportional cap at the boundary). Feeds `setClipFades(...)`.
    public static func fadeInBeats(
        forLocalX x: CGFloat, length: Double, fadeOutBeats: Double, pixelsPerBeat: CGFloat
    ) -> Double {
        let raw = Double(x / pixelsPerBeat)
        return raw.clamped(to: 0...max(0, length - fadeOutBeats))
    }

    /// Fade-out length (beats) for a grip dragged to clip-local `x` (measured back
    /// from the clip's right edge), clamped to `[0, length - fadeIn]`.
    public static func fadeOutBeats(
        forLocalX x: CGFloat, clipWidth: CGFloat, length: Double,
        fadeInBeats: Double, pixelsPerBeat: CGFloat
    ) -> Double {
        let raw = Double((clipWidth - x) / pixelsPerBeat)
        return raw.clamped(to: 0...max(0, length - fadeInBeats))
    }

    /// Flips a fade's curve for an alt/option-click on its grip.
    public static func toggledCurve(_ curve: FadeCurve) -> FadeCurve {
        curve == .linear ? .equalPower : .linear
    }

    // MARK: - Split

    /// The timeline beat a split should land on, or nil when it can't be placed
    /// STRICTLY inside the clip (the store rejects a boundary split). Snaps first;
    /// if the snapped beat falls on/outside a boundary, falls back to the exact
    /// (unsnapped) beat when THAT is strictly inside, else nil. Shared by the
    /// double-click-at-cursor and split-at-playhead paths.
    public static func snappedSplit(
        timelineBeatRaw: Double, clipStart: Double, clipLength: Double,
        snap: ClipSnap, meterMap: MeterMap
    ) -> Double? {
        let end = clipStart + clipLength
        let snapped = snap.snap(beat: timelineBeatRaw, meterMap: meterMap)
        if snapped > clipStart, snapped < end { return snapped }
        if timelineBeatRaw > clipStart, timelineBeatRaw < end { return timelineBeatRaw }
        return nil
    }

    // MARK: - Gain

    /// Adjusts a clip's gain by a dB delta, clamped to `Clip.gainDbRange`.
    public static func adjustedGainDb(_ db: Double, deltaDb: Double) -> Double {
        (db + deltaDb).clamped(to: Clip.gainDbRange)
    }

    /// SF Mono readout for a clip gain in dB: `0` → `"0.0 dB"`, `+3` → `"+3.0 dB"`,
    /// `-6` → `"-6.0 dB"`. One decimal, explicit `+` above unity, `-0.0` folded to
    /// `"0.0"` — matching the mixer's dB style so faders and clip gains agree.
    public static func gainDbString(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0.0 dB" }
        let sign = rounded > 0 ? "+" : ""
        return sign + String(format: "%.1f", rounded) + " dB"
    }
}
