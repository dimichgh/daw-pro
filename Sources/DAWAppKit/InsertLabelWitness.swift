import CoreGraphics
import Foundation

/// One thing an `InsertRow` measured while drawing itself (m23-s).
///
/// **Every case carries a number or a string that came OUT of the view, at the
/// place the view produced it.** Nothing here is re-derived, and nothing is
/// stitched together from two lexical sites — that is the m23-p2 law (a reporter
/// beside the draw can be decoupled from it; an ink mutation ran 51/51 GREEN
/// against a reporter that sat in a sibling `.onChange`) and the m23-o2 law (two
/// reads of the same quantity are equal only by a convention nobody stated).
public struct InsertRowProbe: Sendable {
    public enum Event: Sendable {
        /// The drawn name `Text`: the string it was built from and its own frame
        /// in the row's named coordinate space (ONE read — origin and size).
        case label(String, CGRect)
        /// The argument handed to `.fixedSize(horizontal:)` on that same `Text`.
        /// True = a pinned control label, false = a truncating soft name.
        case pin(Bool)
        /// The hidden twin's width — the same string's single-line ideal.
        case intrinsic(CGFloat)
        /// The name LINE's own measured width (the row minus its padding).
        case line(CGFloat)
        /// The width the gain-reduction underline's `Canvas` was drawn at.
        /// **Layout-driven, and that is why it is separate from the tick below.**
        /// A `GeometryReader` re-evaluates when geometry changes, not once per
        /// animation frame — measured: with the fraction reported from the
        /// underline's `.background`, a 2 s window at 10 Hz counted **0 ticks**
        /// while the layer was demonstrably drawing. A reporter can sit beside
        /// the draw and still be counting the wrong thing.
        case barWidth(CGFloat)
        /// One gain-reduction underline TICK: the fraction the layer resolved
        /// for drawing, reported from inside the `TimelineView` closure that
        /// produces it and RETURNED to the `Canvas` that draws it.
        case barTick(fraction: Double)
    }

    public var effectID: UUID
    /// nil = the MASTER chain (the `MixerInsertsSection` convention).
    public var trackID: UUID?
    /// `EffectDescriptor.Kind.rawValue`, handed in by the row.
    public var kind: String
    public var event: Event

    public init(effectID: UUID, trackID: UUID?, kind: String, event: Event) {
        self.effectID = effectID
        self.trackID = trackID
        self.kind = kind
        self.event = event
    }
}

/// The **insert-row label witness** (m23-s) — the seam that turns "this insert's
/// name is drawn whole" into a MEASURABLE claim.
///
/// ## Why this exists
///
/// m23-s was filed from a pixel-reviewed capture, because nothing in the app
/// reported a drawn insert-row label: `debug.` carried `mixerStripDrag`,
/// `mixerAddAU` and `insertSpectrumSeed`, and not one read of a name. A law that
/// a control label never truncates cannot be regression-tested by a screenshot
/// someone squints at.
///
/// ## What makes an assertion possible
///
/// `intrinsicWidth > drawnWidth` is what truncation looks like from here, and it
/// is the only honest way to state either half of the m23-s classification: a
/// built-in name must NOT be cut, an `.audioUnit` name must STILL be cut. Both
/// numbers come from the layout — the drawn `Text`'s frame and a hidden twin
/// built by the same builder from the same string — so for a PINNED label the
/// two must be equal, and that equality doubles as a check that the twin has not
/// drifted from the drawn label's type.
///
/// `pinned` is stored separately from the label reading for the same reason
/// `lineWidth` is: it is produced at a different modifier (`fixedSize`) than the
/// string and the frame (`Text` + its `GeometryReader`). Merging them into one
/// struct at the call site would mean one report describing three modifiers, and
/// a mutation to any one of them could leave the report unchanged.
///
/// ## Cost
///
/// A few dictionary writes per laid-out insert row, and one scalar write per GR
/// underline frame. Held `@ObservationIgnored` by the app model (the
/// `LiveLayerWitness` pattern), so recording from inside a `GeometryReader` or a
/// `TimelineView` closure schedules no view invalidation.
@MainActor
public final class InsertLabelWitness {

    /// One rendered insert row's name, as drawn.
    public struct LabelReading: Equatable, Sendable {
        public var effectID: UUID
        public var trackID: UUID?
        public var kind: String
        /// The string the `Text` was built from.
        public var label: String
        /// The drawn `Text`'s own measured width.
        public var drawnWidth: CGFloat
        /// The label's leading edge within the row's name line.
        public var originX: CGFloat

        public init(effectID: UUID, trackID: UUID?, kind: String, label: String,
                    drawnWidth: CGFloat, originX: CGFloat) {
            self.effectID = effectID
            self.trackID = trackID
            self.kind = kind
            self.label = label
            self.drawnWidth = drawnWidth
            self.originX = originX
        }
    }

    /// What one insert's gain-reduction underline drew on its last frame — the
    /// m22-e poll-discipline guard, in the `LiveLayerWitness` shape. `ticks`
    /// climbing while the app is NOT frontmost is the only proof that the bar
    /// still rides its own UNPAUSED `.periodic` timeline after m23-s moved it
    /// out of the name line.
    public struct BarReading: Equatable, Sendable {
        public var ticks: Int = 0
        /// The fraction the layer resolved FOR DRAWING (handed in, never
        /// recomputed here — the `LiveLayerWitness` M9 rule).
        public var fraction: Double = 0
        /// The width the underline's own `Canvas` was drawn at. Read ONCE,
        /// inside the layer, because it is now the name line's width and a
        /// second read of one quantity is the m23-o2 coordinate-space hole.
        /// Layout-driven — it does not advance with `ticks`, by design.
        public var width: CGFloat = 0
        public init() {}
    }

    /// Keyed by effect id — unique within a chain, and the id every gate already
    /// holds from `fx.add` / `debug.mixerAddAU`. **Four stores, not one struct**:
    /// each number is written only where it was measured (see the type doc).
    public private(set) var labels: [UUID: LabelReading] = [:]
    public private(set) var pins: [UUID: Bool] = [:]
    public private(set) var intrinsics: [UUID: CGFloat] = [:]
    public private(set) var lines: [UUID: CGFloat] = [:]
    public private(set) var bars: [UUID: BarReading] = [:]

    public init() {}

    /// Files one measurement. The row hands over what it drew; this stores it.
    public func record(_ probe: InsertRowProbe) {
        let id = probe.effectID
        switch probe.event {
        case .label(let string, let frame):
            labels[id] = LabelReading(effectID: id, trackID: probe.trackID,
                                      kind: probe.kind, label: string,
                                      drawnWidth: frame.width, originX: frame.minX)
        case .pin(let pinned):
            pins[id] = pinned
        case .intrinsic(let width):
            intrinsics[id] = width
        case .line(let width):
            lines[id] = width
        case .barWidth(let width):
            var reading = bars[id] ?? BarReading()
            reading.width = width
            bars[id] = reading
        case .barTick(let fraction):
            var reading = bars[id] ?? BarReading()
            reading.ticks &+= 1
            reading.fraction = fraction
            bars[id] = reading
        }
    }

    /// Zeroes the bar tick COUNTS and keeps the last drawn values — the
    /// `LiveLayerWitness.resetTicks` contract: `ticks == 0` beside a live value
    /// is the freeze signature, so the values are deliberately retained.
    public func resetBarTicks() {
        for key in bars.keys { bars[key]?.ticks = 0 }
    }

    /// Drops every reading. For a gate that rebuilds a chain and must not read a
    /// removed insert's stale row.
    public func clear() {
        labels.removeAll()
        pins.removeAll()
        intrinsics.removeAll()
        lines.removeAll()
        bars.removeAll()
    }
}
