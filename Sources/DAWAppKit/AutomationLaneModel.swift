import CoreGraphics
import Foundation
import DAWCore

/// The automation parameters the arrange lane editor exposes in v0: volume and
/// pan only. The domain `AutomationTarget` enum also models `.sendLevel` and
/// `.effectParam`, but the v0 store rejects send-level and the picker stays on
/// the two targets that have a live engine read path (docs/DESIGN-LANGUAGE.md
/// rule 6 — beginner-first labels). Pure value type so the picker, the editor,
/// and the tests share one source of truth.
public enum AutomationParam: String, CaseIterable, Sendable, Equatable {
    case volume
    case pan

    /// The domain target this param creates/selects a lane for.
    public var target: AutomationTarget {
        switch self {
        case .volume: .volume
        case .pan: .pan
        }
    }

    /// The value range the param drives — the SAME ranges the manual fader/knob
    /// clamp through, so the editor's drag math never disagrees with the store.
    public var range: ClosedRange<Double> {
        switch self {
        case .volume: Track.volumeRange
        case .pan: Track.panRange
        }
    }

    /// Full picker label ("Volume" / "Pan").
    public var label: String {
        switch self {
        case .volume: "Volume"
        case .pan: "Pan"
        }
    }

    /// Compact chip label ("VOL" / "PAN").
    public var shortLabel: String {
        switch self {
        case .volume: "VOL"
        case .pan: "PAN"
        }
    }

    /// The neutral resting value (unity gain / center pan) — where a lane sits
    /// when it has no points, and the guide line the editor draws.
    public var neutralValue: Double {
        switch self {
        case .volume: 1
        case .pan: 0
        }
    }

    /// Maps a domain target back to a v0 UI param, or nil for a target the
    /// picker doesn't surface (send/effect lanes an agent may have authored).
    public init?(target: AutomationTarget) {
        switch target {
        case .volume: self = .volume
        case .pan: self = .pan
        case .sendLevel, .effectParam: return nil
        }
    }

    /// The cursor readout for a value, formatted per target: volume as a dB-style
    /// gain string (reusing the mixer's `dbString`, so faders and lanes agree),
    /// pan as an L/C/R side/percent string. So the readout never lies, callers
    /// pass a value already clamped to `range` (the editor and the store both do).
    public func readout(_ value: Double) -> String {
        switch self {
        case .volume: MixerFormat.dbString(forGain: value) + " dB"
        case .pan: MixerFormat.panString(value)
        }
    }
}

/// Beat↔x / value↔y mapping and breakpoint hit-testing for one automation lane,
/// aligned to the arrange timeline's fixed pixels-per-beat so a lane's points
/// line up under the clips that drive them. A value type carrying only the
/// lane's geometry (scale, height, range) — pure, `Equatable`, headless-testable.
///
/// Coordinate space (content coordinates, before scrolling): x grows right with
/// beats (`x = beat * pixelsPerBeat`); y grows DOWN as value FALLS, so the top of
/// the lane is the range maximum and a louder/righter value sits higher — the
/// fader/knob intuition. A vertical inset keeps top/bottom breakpoints off the
/// lane edges so their glow dots aren't clipped.
public struct AutomationGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat` so the lane
    /// registers with the clip grid.
    public var pixelsPerBeat: CGFloat
    /// Full drawn lane height.
    public var laneHeight: CGFloat
    /// Padding at the top and bottom the value mapping stays inside.
    public var verticalInset: CGFloat
    /// The value range the lane drives (volume 0…2, pan -1…1).
    public var range: ClosedRange<Double>
    /// Grab radius (points) for hit-testing a breakpoint.
    public var hitRadius: CGFloat

    public init(
        pixelsPerBeat: CGFloat = 16,
        laneHeight: CGFloat = 64,
        verticalInset: CGFloat = 11,
        range: ClosedRange<Double>,
        hitRadius: CGFloat = 10
    ) {
        self.pixelsPerBeat = pixelsPerBeat
        self.laneHeight = laneHeight
        self.verticalInset = verticalInset
        self.range = range
        self.hitRadius = hitRadius
    }

    // MARK: - Horizontal (beats)

    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    /// Beat at an x, floored at 0 (a breakpoint can never sit before bar 1).
    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    // MARK: - Vertical (value)

    /// The height the value maps across, inside the insets (always >= 1).
    public var usableHeight: CGFloat { max(1, laneHeight - verticalInset * 2) }

    /// Travel fraction (0 = range min, 1 = range max) for a value, clamped.
    public func fraction(forValue value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    /// y for a value — range max at the top inset, range min at the bottom inset.
    public func y(forValue value: Double) -> CGFloat {
        verticalInset + usableHeight * (1 - CGFloat(fraction(forValue: value)))
    }

    /// Value at a y, clamped to `range` — mirrors the store's clamp so a drag's
    /// readout matches what the store will persist.
    public func value(forY y: CGFloat) -> Double {
        let f = (usableHeight - (y - verticalInset)) / usableHeight
        let raw = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
        return raw.clamped(to: range)
    }

    /// A breakpoint's screen position in content coordinates.
    public func point(for point: AutomationPoint) -> CGPoint {
        CGPoint(x: x(forBeat: point.beat), y: y(forValue: point.value))
    }

    // MARK: - Hit testing

    /// Index of the breakpoint nearest `location` within `hitRadius`, or nil for
    /// empty space. Ties resolve to the closer point; equal distance keeps the
    /// earlier index. `points` is indexed as-passed (the editor's draft order).
    public func hitTest(_ location: CGPoint, points: [AutomationPoint]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let p = self.point(for: point)
            let distance = hypot(p.x - location.x, p.y - location.y)
            guard distance <= hitRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }
}

/// Pure breakpoint-array edits for the lane editor. Every op returns a NEW array
/// (whole-array replace — the shape `ProjectStore.setAutomationPoints` takes) and
/// clamps values to the target range so the editor's local state never drifts out
/// of what the store would accept. Add/move do NOT re-sort: the editor keeps a
/// stable index through a drag and lets the store canonicalize on commit (points
/// re-order by beat there, so the editor re-reads the canonical result after the
/// gesture rather than assuming its own order).
public enum AutomationEdit {
    /// Appends a breakpoint (clamped, beat floored at 0) at the END of the array.
    /// The new point is the last element so the caller can drag it by index; the
    /// store sorts on commit.
    public static func addPoint(
        _ points: [AutomationPoint], atBeat beat: Double, value: Double,
        in range: ClosedRange<Double>
    ) -> [AutomationPoint] {
        var out = points
        out.append(AutomationPoint(beat: max(0, beat), value: value.clamped(to: range)))
        return out
    }

    /// Moves the breakpoint at `index` to a new beat/value (clamped, beat floored)
    /// while preserving its curve. Out-of-range index is a no-op.
    public static func movePoint(
        _ points: [AutomationPoint], index: Int, toBeat beat: Double, value: Double,
        in range: ClosedRange<Double>
    ) -> [AutomationPoint] {
        guard points.indices.contains(index) else { return points }
        var out = points
        out[index] = AutomationPoint(
            beat: max(0, beat), value: value.clamped(to: range), curve: out[index].curve)
        return out
    }

    /// Removes the breakpoint at `index` (no-op if out of range).
    public static func removePoint(_ points: [AutomationPoint], index: Int) -> [AutomationPoint] {
        guard points.indices.contains(index) else { return points }
        var out = points
        out.remove(at: index)
        return out
    }
}

/// Resolves which lane a track is editing and which params already have lanes —
/// the small selection logic behind the disclosure row's picker and glow.
public enum AutomationLaneSelection {
    /// The lane a track is currently editing: the explicit selection if it still
    /// exists, else the first lane, else nil (no lanes yet).
    public static func selectedLane(in track: Track, selection: UUID?) -> AutomationLane? {
        if let id = selection, let lane = track.automation.first(where: { $0.id == id }) {
            return lane
        }
        return track.automation.first
    }

    /// The existing lane for a v0 param on a track, or nil (drives whether the
    /// picker chip creates or just selects).
    public static func lane(for param: AutomationParam, in track: Track) -> AutomationLane? {
        track.automation.first { AutomationParam(target: $0.target) == param }
    }

    /// True when any lane on the track is enabled AND has points — the state the
    /// disclosure glyph glows for ("this track is actively automated").
    public static func hasActiveLane(_ track: Track) -> Bool {
        track.automation.contains { $0.isEnabled && !$0.points.isEmpty }
    }
}
