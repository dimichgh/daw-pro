import CoreGraphics
import Foundation
import Observation
import DAWCore

/// All geometry + edit logic for the piano-roll CONTROLLER STRIP (m16-b4), kept
/// UI-free so it unit-tests headless (Sources/DAWAppKit) while the SwiftUI view
/// (`ControllerLaneStrip`) stays thin over it — the `PianoRollModel` discipline
/// (`PianoRollModel.swift:47-59`). It edits ONE visible lane at a time: a local
/// `draft` point array (index-stable through a gesture — the store canonicalizes
/// on commit, the `AutomationLaneModel` contract), submitted as the whole-lane
/// array through `ProjectStore.setControllerLane` — the SAME store call the
/// `clip.setControllerLane` wire verb uses — on gesture END only (one undo per
/// gesture, the `clip.setNotes` submit contract).
///
/// Coordinate space (content coordinates, before scrolling):
///  - x grows right with beats: `x = beat * pixelsPerBeat` (the affine reused
///    from `PianoRollModel.x(forBeat:)`, so the strip registers under the grid).
///  - y grows DOWN as value FALLS: the top of the strip is the type's range
///    maximum, the bottom is 0 — the fader intuition. Bend's center (8192) lands
///    near mid-height, where the view draws its center guideline.
@MainActor
@Observable
public final class ControllerStripModel {
    // MARK: Layout constants

    /// Strip height (design-m16b §9: 72 pt, directly under the 66 pt velocity lane).
    public nonisolated static let laneHeight: CGFloat = 72
    /// The strip splits into a chip-selector row + a 1 pt divider + the value
    /// Canvas, and the three bands sum EXACTLY to `laneHeight` (no sub-pixel clip).
    /// One source of truth with the view, which reads these for its frames.
    public nonisolated static let chipRowHeight: CGFloat = 24
    public nonisolated static let dividerHeight: CGFloat = 1
    /// The value-editing Canvas height — the strip minus the chip row and divider
    /// (72 − 24 − 1 = 47). VALUE↔y maps over THIS (via `usableHeight`), not the full
    /// strip, so the drawn stepped line + handles land exactly where the model
    /// hit-tests: the Canvas is framed at this height, so `size.height` matches.
    public nonisolated static let canvasHeight: CGFloat = laneHeight - chipRowHeight - dividerHeight
    /// Horizontal scale — shares the piano roll's 32 pt/beat so the strip lines up
    /// under the note grid (kept in lockstep with `PianoRollModel.defaultPixelsPerBeat`;
    /// a literal because that constant is MainActor-isolated and this is nonisolated).
    public nonisolated static let defaultPixelsPerBeat: CGFloat = 32
    /// Clear space kept at the top AND bottom edge so top/bottom handles aren't
    /// clipped (the `AutomationGeometry` vertical-inset idiom).
    public nonisolated static let verticalInset: CGFloat = 8
    /// Grab radius (points) for hit-testing a point handle.
    public nonisolated static let hitRadius: CGFloat = 10
    /// Handles hide when the lane is denser than this many points per pixel:
    /// captured continuous-controller runs render as the stepped line only
    /// (design-m16b §9). A named constant so the view and the pin test agree.
    public nonisolated static let handleDensityThreshold: Double = 4
    /// The submit cap (design-m16b §7) — ONE source of truth with the store's
    /// `setControllerLane`, which throws above it. `buildSubmission` decimates to
    /// stay at or under it so the strip never hands the store an over-cap array.
    /// MainActor-isolated (it reads the store's MainActor static); `buildSubmission`
    /// runs on the actor, so this is reachable there.
    public static var maxPoints: Int { ProjectStore.maxControllerPointsPerLane }

    /// Two points at the same beat are the same tick (a pencil stroke re-touching
    /// a column replaces rather than stacks).
    private nonisolated static let beatEpsilon: Double = 1e-6

    public var pixelsPerBeat: CGFloat
    /// Clip length in beats — defines the strip's drawn width.
    public var clipLengthBeats: Double

    // MARK: Lane state

    /// The clip's existing controller lanes in canonical order — the chip row
    /// enumerates these. Reseeded from the store's returned clip after each commit
    /// (the bar-ops reseed idiom) so chips stay live.
    public private(set) var lanes: [MIDIControllerLane]
    /// The visible lane's type, or nil when the clip has no lanes and none has been
    /// staged via the "+" menu. A staged-but-uncommitted type is legal (its `draft`
    /// is empty until the first pencil stroke).
    public private(set) var selectedType: MIDIControllerType?
    /// Working points for the visible lane. Index-stable during a gesture (a drag
    /// mutates by index; the store canonicalizes on commit, so the view re-reads
    /// the canonical result via `load` afterward).
    public var draft: [MIDIControllerPoint]

    /// Index of the point a drag is moving, captured on drag start (nil for a
    /// pencil stroke or empty space).
    @ObservationIgnored private var dragIndex: Int?

    public init(
        lanes: [MIDIControllerLane] = [],
        clipLengthBeats: Double = 4,
        pixelsPerBeat: CGFloat = ControllerStripModel.defaultPixelsPerBeat
    ) {
        let canon = Clip.canonicalControllerLanes(lanes)
        self.lanes = canon
        self.clipLengthBeats = max(0, clipLengthBeats)
        self.pixelsPerBeat = pixelsPerBeat
        self.selectedType = canon.first?.type
        self.draft = canon.first?.points ?? []
    }

    /// Reseeds the strip from a clip's lanes. Keeps the current selection when its
    /// type still exists (a commit re-reading its own lane leaves selection put),
    /// else falls to the first lane, else clears. Never called mid-gesture.
    public func load(lanes: [MIDIControllerLane], clipLengthBeats: Double) {
        self.lanes = Clip.canonicalControllerLanes(lanes)
        self.clipLengthBeats = max(0, clipLengthBeats)
        self.dragIndex = nil
        if let sel = selectedType, let lane = self.lanes.first(where: { $0.type == sel }) {
            self.selectedType = sel
            self.draft = lane.points
        } else if let first = self.lanes.first {
            self.selectedType = first.type
            self.draft = first.points
        } else {
            self.selectedType = nil
            self.draft = []
        }
    }

    // MARK: - Lane selection

    /// Shows an EXISTING lane (chip tap) or STAGES a lane type not yet on the clip
    /// (a "+" menu pick): the draft loads the lane's points if present, else empty
    /// so the first pencil stroke starts a fresh lane. The commit through
    /// `setControllerLane` is what actually creates it on the clip.
    public func select(type: MIDIControllerType) {
        self.selectedType = type
        self.draft = lanes.first { $0.type == type }?.points ?? []
        self.dragIndex = nil
    }

    /// Chips for the clip's existing lanes, in canonical order, with
    /// beginner-readable labels (design-m16b §9, DESIGN-LANGUAGE rule 6).
    public var laneChips: [LaneChip] {
        lanes.map { LaneChip(type: $0.type, label: Self.label(for: $0.type)) }
    }

    /// A selectable existing-lane chip.
    public struct LaneChip: Identifiable, Sendable, Equatable {
        public var type: MIDIControllerType
        public var label: String
        public var id: String { type.wireKey }
    }

    /// Beginner-readable lane label (design-m16b §9): named for the common
    /// controllers, generic "CC n" otherwise.
    public nonisolated static func label(for type: MIDIControllerType) -> String {
        switch type {
        case .pitchBend: return "Bend"
        case .channelPressure: return "Pressure"
        case .cc(let n):
            switch n {
            case 1: return "Mod (CC 1)"
            case 11: return "Expression (CC 11)"
            case 64: return "Sustain (CC 64)"
            default: return "CC \(n)"
            }
        }
    }

    /// The "+" menu items (design-m16b §9): the common named controllers plus an
    /// "Other CC…" numeric-entry sentinel the view resolves to a picked CC number.
    public enum AddMenuItem: Identifiable, Sendable, Equatable {
        case type(MIDIControllerType, label: String)
        case otherCC

        public var id: String {
            switch self {
            case .type(let t, _): return t.wireKey
            case .otherCC: return "otherCC"
            }
        }

        public var label: String {
            switch self {
            case .type(_, let label): return label
            case .otherCC: return "Other CC…"
            }
        }
    }

    public nonisolated static let addMenuItems: [AddMenuItem] = [
        .type(.pitchBend, label: "Bend"),
        .type(.cc(controller: 1), label: "Mod (CC 1)"),
        .type(.cc(controller: 11), label: "Expression (CC 11)"),
        .type(.cc(controller: 64), label: "Sustain (CC 64)"),
        .type(.channelPressure, label: "Pressure"),
        .otherCC,
    ]

    /// Passive Simple-density header copy: "N controller lanes" when the clip has
    /// any, else nil (nothing to announce). NOT a button in v1 — data is never
    /// hidden, but controller EDITING is a Pro surface (the m15-c master-lane
    /// Pro-only precedent, design-m16b §9). Static so the Simple-mode header can
    /// call it without building the full strip model, and headless-testable.
    public nonisolated static func laneCountSummary(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 controller lane" : "\(count) controller lanes"
    }

    public var laneCountSummary: String? { Self.laneCountSummary(count: lanes.count) }

    // MARK: - Geometry

    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    /// Drawn strip width — the clip length, but never less than the furthest draft
    /// point (out-of-clip points stay visible; the model never trims them).
    public var contentWidth: CGFloat {
        let maxBeat = draft.map(\.beat).max() ?? 0
        return CGFloat(max(clipLengthBeats, maxBeat, 1)) * pixelsPerBeat
    }

    /// The height the value maps across, inside the insets (always >= 1). Measured
    /// over the value Canvas (`canvasHeight`), NOT the full strip, so the drawn line
    /// matches the hit-test space.
    public var usableHeight: CGFloat { max(1, Self.canvasHeight - Self.verticalInset * 2) }

    /// Travel fraction (0 = value 0 at the bottom, 1 = range max at the top) for a
    /// raw value on a lane of `type`. Every value domain has lower bound 0, so this
    /// is `value / max`.
    public func fraction(forValue value: Int, type: MIDIControllerType) -> Double {
        let upper = Double(type.valueRange.upperBound)
        guard upper > 0 else { return 0 }
        return (Double(value) / upper).clamped(to: 0...1)
    }

    /// y for a raw value — range max at the top inset, 0 at the bottom inset.
    public func y(forValue value: Int, type: MIDIControllerType) -> CGFloat {
        Self.verticalInset + usableHeight * (1 - CGFloat(fraction(forValue: value, type: type)))
    }

    /// Raw value at a y, clamped to the type's domain — mirrors the store's clamp
    /// so a drag's readout matches what the store persists.
    public func value(forY y: CGFloat, type: MIDIControllerType) -> Int {
        let f = (usableHeight - (y - Self.verticalInset)) / usableHeight
        let raw = Double(f) * Double(type.valueRange.upperBound)
        return Int(raw.rounded()).clamped(to: type.valueRange)
    }

    /// The center-guideline y for a bend lane (its neutral 8192), else nil — the
    /// view draws the reference line only where bend is centred (design-m16b §9).
    public func centerGuidelineY(type: MIDIControllerType) -> CGFloat? {
        guard case .pitchBend = type else { return nil }
        return y(forValue: type.neutralDefault, type: type)
    }

    /// Handles are hidden once the visible lane is denser than
    /// `handleDensityThreshold` points per pixel (dense captured data draws as the
    /// stepped line only). True by default (a sparse or empty lane shows handles).
    public var handlesVisible: Bool {
        let width = Double(contentWidth)
        guard width > 0 else { return true }
        return Double(draft.count) / width <= Self.handleDensityThreshold
    }

    // MARK: - Hit testing

    /// Index of the draft point nearest `location` within `hitRadius` (2D nearest,
    /// the `AutomationGeometry.hitTest` idiom), or nil for empty space. Points are
    /// identity-free, so a drag targets the NEAREST point (selection-free v1).
    public func hitTest(_ location: CGPoint) -> Int? {
        guard let type = selectedType else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, p) in draft.enumerated() {
            let screen = CGPoint(x: x(forBeat: p.beat), y: y(forValue: p.value, type: type))
            let distance = hypot(screen.x - location.x, screen.y - location.y)
            guard distance <= Self.hitRadius else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    // MARK: - Draft edits

    /// The value in effect at `beat` on the CURRENT draft (stepwise: the latest
    /// point at or before `beat`), or nil when nothing precedes it. Used for the
    /// pencil's duplicate-value drop. Linear scan (the draft is small mid-gesture).
    private func draftValue(atBeat beat: Double) -> Int? {
        var best: (beat: Double, value: Int)?
        for p in draft where p.beat <= beat {
            if best == nil || p.beat > best!.beat { best = (p.beat, p.value) }
        }
        return best?.value
    }

    /// Pencil-inserts a point at a (snapped) beat tick with the pointer's value,
    /// dropping a redundant point when the value already holds there (stepwise
    /// idempotence — a flat drag adds no points). A stroke re-touching the same
    /// tick REPLACES its value. Returns true when the draft changed.
    @discardableResult
    public func pencilInsert(atBeat beat: Double, value: Int) -> Bool {
        guard let type = selectedType else { return false }
        let b = max(0, beat)
        let v = value.clamped(to: type.valueRange)
        // Same tick → replace in place (index-stable).
        if let index = draft.firstIndex(where: { abs($0.beat - b) < Self.beatEpsilon }) {
            guard draft[index].value != v else { return false }
            draft[index] = MIDIControllerPoint(beat: b, value: v)
            return true
        }
        // Duplicate-value drop: nothing changes if v already holds at b.
        if draftValue(atBeat: b) == v { return false }
        draft.append(MIDIControllerPoint(beat: b, value: v))
        return true
    }

    /// Begins dragging the point nearest `location` (nil-safe: false when empty
    /// space, so the caller falls through to a pencil stroke). Selection-free.
    @discardableResult
    public func beginDrag(at location: CGPoint) -> Bool {
        dragIndex = hitTest(location)
        return dragIndex != nil
    }

    /// Moves the drag's point to a new beat/value (clamped to >= 0 and the type
    /// domain). A no-op when no drag is active.
    public func dragPoint(toBeat beat: Double, value: Int) {
        guard let type = selectedType, let index = dragIndex, draft.indices.contains(index) else { return }
        draft[index] = MIDIControllerPoint(beat: max(0, beat), value: value.clamped(to: type.valueRange))
    }

    public func endDrag() { dragIndex = nil }

    /// Removes the point nearest `location` (option-click delete). Returns true
    /// when a point was removed.
    @discardableResult
    public func removePoint(at location: CGPoint) -> Bool {
        guard let index = hitTest(location) else { return false }
        draft.remove(at: index)
        dragIndex = nil
        return true
    }

    /// Clears the visible lane's points (the "Remove lane" affordance commits an
    /// empty array, which the store treats as delete-the-lane).
    public func clearDraft() {
        draft = []
        dragIndex = nil
    }

    // MARK: - Submission

    /// The whole-lane point array to hand to `ProjectStore.setControllerLane` on
    /// gesture end: canonicalized (sorted, clamped, equal-beat last-wins) and
    /// decimated to `maxPoints` so the store never sees an over-cap array. Empty
    /// when no lane is selected (nothing to submit).
    public func buildSubmission() -> [MIDIControllerPoint] {
        guard let type = selectedType else { return [] }
        var points = MIDIControllerLane.canonicalPoints(draft, type: type)
        if points.count > Self.maxPoints {
            points = Self.decimate(points, to: Self.maxPoints)
        }
        return points
    }

    /// Even-stride decimation to `cap`, keeping the endpoints and strictly
    /// increasing indices so the canonical (distinct-beat, ascending) input stays
    /// canonical (design-m16b §7 second-stage widening, in spirit). Only reached
    /// by pathological over-cap drafts — a normal pencil gesture stays far below.
    nonisolated static func decimate(_ points: [MIDIControllerPoint], to cap: Int) -> [MIDIControllerPoint] {
        guard points.count > cap, cap > 1 else { return Array(points.prefix(max(0, cap))) }
        var out: [MIDIControllerPoint] = []
        out.reserveCapacity(cap)
        let stride = Double(points.count - 1) / Double(cap - 1)
        var lastIndex = -1
        for i in 0..<cap {
            var index = Int((Double(i) * stride).rounded())
            if index <= lastIndex { index = lastIndex + 1 }
            guard index < points.count else { break }
            out.append(points[index])
            lastIndex = index
        }
        return out
    }
}
