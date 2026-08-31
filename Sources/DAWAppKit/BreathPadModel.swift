import CoreGraphics
import Foundation
import Observation
import DAWCore

// MARK: - Geometry

/// The pad's pure geometry: where a dot at `(angle, radius)` draws, and what a
/// point in the pad's own coordinate space means as a dot (breath pad P7).
///
/// Non-isolated and value-typed on purpose — this is the `LoopRulerGeometry` /
/// `MIDIMapGeometry` idiom. Every hit-test and every drawn position comes from
/// here, so the view can only draw the dot where the model believes it is.
///
/// ## The angle convention, stated once
///
/// `EffortRing.angle(ofIndex:)` puts pattern 0 at **0 rad** and steps
/// anticlockwise in the mathematical sense. The pad draws it the way the user
/// described it — **index 0 at the TOP, going CLOCKWISE** — so the map is
///
/// ```
/// x = cx + R·r·sin(φ)        φ = atan2(dx, −dy)
/// y = cy − R·r·cos(φ)        r = hypot(dx, dy) / R
/// ```
///
/// which is a rotation, not a re-ordering: the ring's own index order is
/// untouched, so a `ringAngle` sent over the wire and a dot placed by hand mean
/// the same thing.
public struct BreathPadGeometry: Sendable, Equatable {
    /// The pad's square side, in points.
    public var side: CGFloat

    /// How much of the half-side the pattern ring takes. The rest is the label
    /// gutter — the names sit OUTSIDE the ring so a dot at full radius never
    /// lands under its own label.
    public static let ringFraction: CGFloat = 0.62
    /// The drawn dot's radius.
    public static let dotRadius: CGFloat = 7
    /// How far from the dot a press still counts as grabbing it. Generous,
    /// because the alternative — a press that misses — silently starts a new
    /// gesture somewhere else.
    public static let grabSlop: CGFloat = 22
    /// The pad's default drawn size.
    public static let defaultSide: CGFloat = 288

    public init(side: CGFloat = BreathPadGeometry.defaultSide) {
        self.side = max(1, side)
    }

    public var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    /// The radius, in points, that dot-radius 1 draws at.
    public var ringRadius: CGFloat { side / 2 * Self.ringFraction }

    /// How far OUTSIDE the rim a pattern's name sits.
    ///
    /// ⚠️ Additive, not a fraction of the gutter, and MEASURED from a render: at
    /// a fraction the 45° names (two lines each) sat close enough to the rim
    /// that a dot at full radius drew ON TOP of its own label — visible in the
    /// first capture of this panel, invisible to every test in it. 24 pt clears
    /// a two-line name by ~14 pt at every ring position.
    public static let labelGap: CGFloat = 24

    /// Where a pattern's NAME sits — outside the ring, in the gutter.
    public var labelRadius: CGFloat { ringRadius + Self.labelGap }

    /// Where a dot draws.
    public func point(angle: Double, radius: Double) -> CGPoint {
        let r = ringRadius * CGFloat(min(1, max(0, radius)))
        return CGPoint(x: center.x + r * CGFloat(sin(angle)),
                       y: center.y - r * CGFloat(cos(angle)))
    }

    public func point(of dot: DotPosition) -> CGPoint {
        point(angle: dot.angle, radius: dot.radius)
    }

    /// What a point in the pad means. **Radius is clamped to 1, never
    /// extrapolated** — dragging past the rim parks the dot ON the rim, which is
    /// what a physical detent does and what keeps `radius` inside the range the
    /// wire accepts.
    public func dot(at point: CGPoint) -> DotPosition {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        // atan2(dx, -dy): 0 at the top, growing clockwise. The inverse of
        // `point(angle:radius:)` exactly.
        let angle = EffortRing.wrap(atan2(dx, -dy))
        let radius = min(1, (dx * dx + dy * dy).squareRoot() / Double(ringRadius))
        return DotPosition(angle: angle, radius: radius)
    }

    /// Where pattern `index` of a ring of `count` sits, at a fraction of the
    /// ring radius (1 = on the rim, `labelScale` = out in the gutter).
    public func patternPoint(index: Int, count: Int, radiusScale: CGFloat = 1) -> CGPoint {
        guard count > 0 else { return center }
        let angle = 2 * Double.pi * Double(((index % count) + count) % count) / Double(count)
        let r = ringRadius * radiusScale
        return CGPoint(x: center.x + r * CGFloat(sin(angle)),
                       y: center.y - r * CGFloat(cos(angle)))
    }

    /// The label anchor for pattern `index`, in the gutter.
    public func labelPoint(index: Int, count: Int) -> CGPoint {
        patternPoint(index: index, count: count, radiusScale: labelRadius / ringRadius)
    }

    /// Is this press on the dot? Used to tell "grab the dot" from "jump the dot
    /// here", which are the same gesture with a different feel.
    public func isOnDot(_ point: CGPoint, dot: DotPosition) -> Bool {
        let p = self.point(of: dot)
        return hypot(point.x - p.x, point.y - p.y) <= Self.grabSlop
    }

    /// The pattern whose NAME was pressed, or nil. A ring of names that cannot
    /// be aimed at is decoration; §8.2's whole argument for nearest-two
    /// weighting is that parking the dot exactly on a pattern must be possible.
    ///
    /// ⚠️ **The names are hit-tested HERE, not by a `Text`'s own tap gesture**,
    /// and that is a correctness fix rather than a preference. A tappable label
    /// sitting inside the pad's `DragGesture(minimumDistance: 0)` gets BOTH: the
    /// drag opens and jumps the dot, the tap then parks it again, and one click
    /// spends TWO undo steps. Resolving the name geometrically inside the one
    /// gesture leaves exactly one commit path.
    ///
    /// The band is OUTSIDE the rim (`labelGap` and beyond) so that pressing the
    /// rim itself is still an ordinary dot placement.
    public func patternHit(_ point: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let reach = hypot(point.x - center.x, point.y - center.y)
        guard reach > ringRadius + Self.labelGap * 0.4 else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<count {
            let p = labelPoint(index: index, count: count)
            let d = hypot(point.x - p.x, point.y - p.y)
            if d <= Self.grabSlop * 1.6, best == nil || d < best!.distance {
                best = (index, d)
            }
        }
        return best?.index
    }
}

// MARK: - The card's height budget

/// How tall the pad's card is allowed to be, and **which region yields**
/// (docs/DESIGN-LANGUAGE.md, the m26-i centred-card law).
///
/// The law's two halves, decided together:
///
/// 1. **The ceiling is derived from the window, never a constant.**
/// 2. **Exactly one region yields, and it is a DECISION.** Here it is the DIAL:
///    a circle at 176 pt is still a perfectly usable pad, whereas a squeezed
///    air gauge stops being legible and legibility is P4's whole contract. Every
///    other region takes a fixed height, and the warnings block is bounded and
///    INFLEXIBLE (`maxHeight` + `fixedSize`, the RESERVED CLUSTER mechanism), so
///    it can never quietly absorb the shortfall the dial is supposed to take.
///
/// ⚠️ `fixedChrome` is the one number a test cannot derive — every pin consumes
/// it, so all of them stay green when it is wrong. It is MEASURED, and measured
/// from **the panel's own report of what it was given and what it drew**
/// (`BreathPadModel.measuredLayout`, echoed on `debug.breathPad`) rather than
/// summed from paddings or scanned off a capture. Both of those were tried and
/// both were wrong; see the constant.
public enum BreathPadLayout {
    /// The dial at its comfortable size.
    public static let dialCeiling: CGFloat = 288
    /// The floor the dial clamps at — a valve, not a target. A 176 pt circle is
    /// still a perfectly usable pad.
    public static let dialFloor: CGFloat = 176
    /// The warnings block at its comfortable size, and the floor it sheds to.
    /// The floor is ~two lines: a block that can shrink to nothing would let a
    /// warning disappear to make room for a circle.
    public static let warningsCeiling: CGFloat = 92
    public static let warningsFloor: CGFloat = 36
    /// Breathing room between the card and the window edge, top and bottom.
    public static let windowMargin: CGFloat = 24

    /// ⚠️ **MEASURED, NOT SUMMED — AND MEASURED BY THE VIEW, NOT BY ME.**
    ///
    /// 433 pt = the card's DRAWN height (721 pt, reported by the panel itself
    /// through `BreathPadModel.measuredLayout` and echoed on `debug.breathPad`)
    /// minus the dial it was drawn with (288, also reported). Every pin below
    /// CONSUMES this number, so all of them stay green when it is wrong.
    ///
    /// Its history is the argument for the report existing at all:
    ///
    /// | how it was obtained | value | wrong by |
    /// |---|---|---|
    /// | summed from the paddings | 372 | 61 |
    /// | pixel-scanned from a capture | 380 | 53 |
    /// | the view stating what it drew | **433** | — |
    ///
    /// The pixel scan was not merely imprecise, it was UNRESOLVABLE: the card's
    /// measured height, the dial's measured diameter and the window's height each
    /// implied a different `available`, and no combination of the three was
    /// consistent. The card is centred, so its edges move when EITHER the card or
    /// the window changes, and a capture cannot tell those two apart. The view
    /// can, because it is handed one of them.
    ///
    /// ⭐ **The 53 pt error was invisible to every test.** It made the budget
    /// believe the loaded card fitted (predicted 806 against 820 of room) while
    /// it actually drew 857 and overhung by 37 pt — the dial never yielded,
    /// because as far as the arithmetic knew there was nothing to yield.
    ///
    /// ## 433 → 510.5 (m28-knob-ui), measured the same way
    ///
    /// The card gained two unconditional rows: the ANGLE/DEPTH precision knobs
    /// (which REPLACED the plain angle/depth readouts, so the net cost is one
    /// knob's height and not a whole row), and the HARDWARE section's collapsed
    /// disclosure with its divider. **510.5 = 798.5 drawn − 288 dial**, both read
    /// off `debug.breathPad` at an 868 pt window where the card FITS — a reading
    /// taken while the card is clamped by the scroll cascade would be measuring
    /// the clamp, not the card.
    public static let fixedChrome: CGFloat = 510.5
    /// What the warnings block costs the card when there is one: its room plus
    /// the stack spacing above it.
    public static let warningsChrome: CGFloat = 12
    /// What the "never recovered" sentence costs when the budget emits it —
    /// two lines plus spacing (measured the same way: 804 pt with both optional
    /// blocks, against 668 with neither).
    public static let recoveryNoteHeight: CGFloat = 34

    /// ⚠️ **THE THIRD VARIABLE-HEIGHT BLOCK, AND THE ONE THAT NEARLY GOT AWAY.**
    ///
    /// `blendSummary` is DAWCore's own sentence about the dominant gesture, and
    /// the eight of them are not the same length: `flat` is 135 characters and
    /// renders two lines at this card's 372 pt text width, while `subToneEntry`
    /// is 255 and renders FOUR. `fixedChrome` was measured against a two-line
    /// one, so the card grew ~24 pt whenever the dot sat near the long end and
    /// the budget could not see it — the identical shape to the warnings/recovery
    /// defect the render caught, at a quarter of the size.
    ///
    /// The fix is to stop it varying rather than to predict it: the view reserves
    /// this height as a MINIMUM, so every summary occupies the same space and
    /// `fixedChrome` is true for all eight. A minimum and not a fixed frame on
    /// purpose — a future pattern with a longer sentence must WRAP AND PUSH (the
    /// dial then absorbs it, which is the cascade doing its job) rather than
    /// truncate a sentence that explains what the control does. Its length is
    /// pinned by `theSummaryReservationCoversEveryGestureInTheLibrary`.
    ///
    /// MEASURED: four rendered lines at 12 pt of line height in the parked
    /// `subToneEntry` capture.
    public static let summaryReservation: CGFloat = 48

    /// ⚠️ **THE FOURTH VARIABLE-HEIGHT INPUT (m28-knob-ui), and the budget has
    /// now been burned by three of them.** What the HARDWARE section costs the
    /// card when it is EXPANDED — the two mapping rows, the LAST HEARD readout,
    /// the listening line, the persistence note and the clear-all button.
    ///
    /// Its COLLAPSED cost is folded into `fixedChrome`, because the collapsed
    /// row is unconditional: it is the section's diagnostic and it is always on
    /// the card.
    ///
    /// ⛔ **MEASURED THE SAME WAY AS `fixedChrome`, NOT DERIVED FROM IT.** The
    /// tempting move — take `fixedChrome`, add an estimate per row — is exactly
    /// how the summed 372 and the pixel-scanned 380 both came out wrong for the
    /// number above. **285 = 298.5 − 13.5**, the SECTION's own reported height
    /// expanded minus collapsed (`debug.breathPad`'s `hardwareSectionHeight`),
    /// with nothing else changed.
    ///
    /// ⚠️ **IT WAS 260 FOR ONE ROUND, AND 260 WAS A MEASUREMENT OF A SECTION
    /// THAT HAD TWO HEIGHTS.** See `hardwareFeedReservation` below: the section
    /// used to be 273.5 in the unbound state and something else once a mapping
    /// existed, and 260 was the honest delta *of that one sample*. Reserving the
    /// worst case made the section a single height — and made it taller. A
    /// correctly-measured constant for an incorrectly-varying view is still
    /// wrong, and it fails in the state nobody measured.
    ///
    /// ⚠️⚠️ **THE OBVIOUS MEASUREMENT IS THE WRONG ONE, AND IT LOOKS RIGHT.**
    /// The first attempt took the difference between the two CARD heights, the
    /// way `fixedChrome` was obtained. It returned **21.5** — an entirely
    /// plausible-looking number, and wrong by a factor of twelve. On a 900 pt
    /// display the expanded card exceeds its room, so the scroll cascade CLAMPS
    /// it: the difference between the two drawn cards was the difference between
    /// two clamps, not between two cards. A clamped reading is indistinguishable
    /// from a real one, which is this tree's characteristic failure. The section
    /// reports its own height instead — a `ScrollView`'s content keeps its
    /// natural size, so that reading is honest at any window.
    ///
    /// Pinned against the panel's live report by the m28-knob-ui render probe,
    /// which compares this constant to the measured delta rather than to a card
    /// height it might not be able to observe unclamped.
    ///
    /// ⚠️ It moves the card's SCROLL THRESHOLD, and that is the honest cost of
    /// the feature: the card scrolls once `fixedChrome + dial + this` exceeds
    /// the room. The section is collapsed by default so the common case is
    /// unaffected, and the cascade (dial yields → warnings shed → the card
    /// scrolls) already handles the rest without clipping anything.
    public static let hardwareExpandedChrome: CGFloat = 285

    /// ⛔⛔ **AND THE MEASUREMENT ABOVE IS ONLY TRUE BECAUSE THE SECTION IS MADE
    /// NOT TO VARY. This is the constant that buys that.**
    ///
    /// `hardwareExpandedChrome` is ONE number, read in ONE state — unbound and
    /// unsubscribed. The section as first written was two different heights: the
    /// feed line's longest variant ("Not listening yet. Nothing is mapped, so
    /// DAW Pro leaves your MIDI gear alone until you press LEARN.") wraps to two
    /// lines while the other two variants fit on one, and FORGET ALL MAPPINGS
    /// appeared only once something was bound. So the sampled state was the one
    /// state the panel leaves the moment the feature is used, and the delta was
    /// not even reliably negative.
    ///
    /// **That is the P7 defect exactly**: the budget says it fits, the card draws
    /// taller, and the overhang lands on WRITE THE SHAPE — with every test green,
    /// because they all consume the same wrong constant. Worse, the scroll
    /// cascade HIDES it on a 900 pt display, so a render probe cannot see it
    /// either; it would surface only on a window where the expanded card just
    /// fits, i.e. on someone else's screen.
    ///
    /// The fix is the one `summaryReservation` already uses: **reserve the worst
    /// case so the constant is true in every state**, rather than sampling one
    /// state and hoping. The feed line gets two lines' room always; the button is
    /// always present and merely disabled when there is nothing to forget (which
    /// the destructive-action rule wanted anyway). The m28-knob-ui probe asserts
    /// the section reports the SAME height unbound, bound, armed and inverted —
    /// an equality that fails the moment a variable-height control is added here.
    public static let hardwareFeedReservation: CGFloat = 24

    /// What the card WANTS, before anything yields.
    public static func naturalHeight(hasWarnings: Bool, hasRecoveryNote: Bool,
                                     hardwareExpanded: Bool = false) -> CGFloat {
        fixedChrome + dialCeiling
            + (hasWarnings ? warningsCeiling + warningsChrome : 0)
            + (hasRecoveryNote ? recoveryNoteHeight : 0)
            + (hardwareExpanded ? hardwareExpandedChrome : 0)
    }

    /// The two regions that can give height back, in the ORDER they give it.
    ///
    /// **This is the m26-i law's second half, made explicit.** The shortfall
    /// goes where it was DECIDED to go, not wherever a `ScrollView` happens to
    /// sit: the DIAL yields first, all the way to its floor, and only then does
    /// the warnings block shed — because a smaller circle is still a circle
    /// while a hidden warning is a silence. Every other region takes a fixed,
    /// computed height, and the warnings block is `maxHeight` + `fixedSize`, so
    /// it is INFLEXIBLE at `min(content, room)` and cannot absorb the shortfall
    /// out of turn.
    ///
    /// ⛔ **BELOW `minimumCardHeight` THE CARD SCROLLS. It used to overhang, and
    /// "it overhangs symmetrically, nothing clips" was wrong.** At the app's
    /// 640 pt window floor, carrying warnings and the recovery sentence, both
    /// regions are at their floors and the card is 97 pt taller than its room —
    /// and a capture at that size showed the **WRITE THE SHAPE button clipped off
    /// the bottom of the window**. A centred card does not overhang into empty
    /// space; it overhangs into the screen edge, and the rows it loses are the
    /// first and the last, which on this card are dismiss and commit.
    ///
    /// So the cascade has a third step, in the view: dial yields → warnings shed
    /// → **the card scrolls**, with the header and the apply button pinned
    /// outside the scroller. This function keeps returning a card that does not
    /// fit, because that IS the signal the view acts on.
    public static func regions(available: CGFloat, hasWarnings: Bool,
                               hasRecoveryNote: Bool,
                               hardwareExpanded: Bool = false)
        -> (dial: CGFloat, warnings: CGFloat) {
        let room = available - windowMargin * 2
        var shortfall = naturalHeight(hasWarnings: hasWarnings,
                                      hasRecoveryNote: hasRecoveryNote,
                                      hardwareExpanded: hardwareExpanded) - room
        guard shortfall > 0 else { return (dialCeiling, warningsCeiling) }

        let dialGive = min(shortfall, dialCeiling - dialFloor)
        shortfall -= dialGive
        let warningsGive = hasWarnings ? min(shortfall, warningsCeiling - warningsFloor) : 0
        return (dialCeiling - dialGive, warningsCeiling - warningsGive)
    }

    /// The dial's drawn side — the common read.
    public static func dialSide(available: CGFloat, hasWarnings: Bool = false,
                                hasRecoveryNote: Bool = false,
                                hardwareExpanded: Bool = false) -> CGFloat {
        regions(available: available, hasWarnings: hasWarnings,
                hasRecoveryNote: hasRecoveryNote,
                hardwareExpanded: hardwareExpanded).dial
    }

    /// The warnings block's bound at this window.
    public static func warningsRoom(available: CGFloat, hasWarnings: Bool,
                                    hasRecoveryNote: Bool = false,
                                    hardwareExpanded: Bool = false) -> CGFloat {
        regions(available: available, hasWarnings: hasWarnings,
                hasRecoveryNote: hasRecoveryNote,
                hardwareExpanded: hardwareExpanded).warnings
    }

    /// The smallest card the layout can produce — **derived from the floors**,
    /// so a floor can never outrank the ceiling the way m26-i's picked minimum
    /// did.
    public static func minimumCardHeight(hasWarnings: Bool = true,
                                         hasRecoveryNote: Bool = true,
                                         hardwareExpanded: Bool = false) -> CGFloat {
        fixedChrome + dialFloor
            + (hasWarnings ? warningsFloor + warningsChrome : 0)
            + (hasRecoveryNote ? recoveryNoteHeight : 0)
            + (hardwareExpanded ? hardwareExpandedChrome : 0)
    }

    /// The card's height at a given window, after both regions have yielded.
    public static func cardHeight(available: CGFloat, hasWarnings: Bool = false,
                                  hasRecoveryNote: Bool = false,
                                  hardwareExpanded: Bool = false) -> CGFloat {
        let r = regions(available: available, hasWarnings: hasWarnings,
                        hasRecoveryNote: hasRecoveryNote,
                        hardwareExpanded: hardwareExpanded)
        return fixedChrome + r.dial
            + (hasWarnings ? r.warnings + warningsChrome : 0)
            + (hasRecoveryNote ? recoveryNoteHeight : 0)
            + (hardwareExpanded ? hardwareExpandedChrome : 0)
    }
}

// MARK: - The drag trail

/// The recent dot positions of the gesture in flight — the visible "where the
/// hand has been" the user asked for ("the dot is moving between different
/// patterns").
///
/// **Fixed capacity, no per-frame allocation.** The buffer is allocated once at
/// its full size and written in place; `record` never grows an array and never
/// shifts one. A drag at 120 Hz for ten seconds costs exactly the same as a
/// drag at 60 Hz for one (docs/DESIGN-LANGUAGE.md — drawing code must not
/// allocate per frame).
///
/// ⚠️ It is the DRAG trail, not a playback trail. Nothing on this pad animates
/// between gestures, so the view needs no `TimelineView` and there is no
/// continuous redraw to profile — see `BreathPadView`.
public struct BreathPadTrail: Sendable, Equatable {
    /// How many positions the trail remembers. 48 at a 60 Hz drag is 0.8 s of
    /// history — long enough to read as motion, short enough that a slow drag
    /// does not draw a full circle of stale crumbs.
    public static let capacity = 48

    private var storage: [DotPosition]
    private var head: Int
    private var filled: Int

    public init() {
        storage = [DotPosition](repeating: DotPosition(angle: 0, radius: 0),
                                count: Self.capacity)
        head = 0
        filled = 0
    }

    public var count: Int { filled }
    public var isEmpty: Bool { filled == 0 }

    /// Appends in place, overwriting the oldest entry once full.
    public mutating func record(_ dot: DotPosition) {
        storage[head] = dot
        head = (head + 1) % Self.capacity
        filled = Swift.min(Self.capacity, filled + 1)
    }

    public mutating func clear() {
        head = 0
        filled = 0
    }

    /// Oldest → newest, WITHOUT materialising an array — what the Canvas walks.
    /// The drawing path must not allocate per frame, and a drag redraws the
    /// trail on every one of them (docs/DESIGN-LANGUAGE.md).
    public subscript(index: Int) -> DotPosition {
        precondition(index >= 0 && index < filled, "trail index \(index) out of 0..<\(filled)")
        let start = (head - filled + Self.capacity * 2) % Self.capacity
        return storage[(start + index) % Self.capacity]
    }

    /// Oldest → newest as an array. For tests and for callers that genuinely
    /// want one — never on the draw path; use the subscript there.
    public var positions: [DotPosition] {
        guard filled > 0 else { return [] }
        var out: [DotPosition] = []
        out.reserveCapacity(filled)
        let start = (head - filled + Self.capacity * 2) % Self.capacity
        for i in 0..<filled { out.append(storage[(start + i) % Self.capacity]) }
        return out
    }
}

// MARK: - The air gauge's drawable form

/// The air budget's report, turned into the few things a strip can draw
/// (design §9.4 layer 4). Pure and non-isolated, so the derivation that decides
/// whether the panel says **did** or **would** is testable without a window.
///
/// ⛔ **`applied` is read on EVERY sentence here, and that is the point.**
/// `AirBudget.Report` is computed on every apply whether or not enforcement is
/// on: with `enforced == false` the lane was NOT touched and the whole report is
/// a counterfactual. A gauge that read `constrainedNotes` and ignored `applied`
/// would tell the composer that notes were pulled down when nothing was — this
/// tree's characteristic failure, in the one surface that exists to prevent it.
public struct BreathPadAirGauge: Sendable, Equatable {

    /// One phrase, as the strip draws it.
    public struct Phrase: Sendable, Equatable {
        public var startBeat: Double
        public var endBeat: Double
        /// Air at the start and end of the phrase, 0…1 — the strip's height.
        public var airAtStart: Double
        public var airAtEnd: Double
        public var lowestAir: Double
        /// Did air fall below the reserve? The strip shades these amber.
        public var exhausted: Bool
        public var constrainedNoteCount: Int
    }

    /// A breath, drawn as a mark at the beat the gap began.
    public struct BreathMark: Sendable, Equatable {
        public var beat: Double
        public var seconds: Double
        /// A real breath (long enough) or a gap too short to breathe in. Two
        /// marks, because they have opposite fixes.
        public var taken: Bool
    }

    public var phrases: [Phrase]
    public var breaths: [BreathMark]
    /// The beat span the strip covers. Equal bounds mean there is nothing to
    /// draw (no notes).
    public var startBeat: Double
    public var endBeat: Double
    /// Did enforcement actually reach the lane?
    public var applied: Bool
    public var constrainedNoteCount: Int
    public var notesConsidered: Int
    public var maxAttenuationDb: Double
    public var lowestAir: Double
    public var neverRecovered: Bool

    /// The empty gauge — no report yet. Distinct from "a report that found
    /// nothing", which is a real answer.
    public static let unknown = BreathPadAirGauge(
        phrases: [], breaths: [], startBeat: 0, endBeat: 0, applied: false,
        constrainedNoteCount: 0, notesConsidered: 0, maxAttenuationDb: 0,
        lowestAir: 1, neverRecovered: false, hasReport: false)

    /// False before the first apply — see `unknown`.
    public var hasReport: Bool

    public init(phrases: [Phrase], breaths: [BreathMark], startBeat: Double,
                endBeat: Double, applied: Bool, constrainedNoteCount: Int,
                notesConsidered: Int, maxAttenuationDb: Double, lowestAir: Double,
                neverRecovered: Bool, hasReport: Bool) {
        self.phrases = phrases
        self.breaths = breaths
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.applied = applied
        self.constrainedNoteCount = constrainedNoteCount
        self.notesConsidered = notesConsidered
        self.maxAttenuationDb = maxAttenuationDb
        self.lowestAir = lowestAir
        self.neverRecovered = neverRecovered
        self.hasReport = hasReport
    }

    /// Builds the strip from the store's own report. Nothing is recomputed —
    /// every number here came from `AirBudget.sweep` via
    /// `EffortShapeApplication.air`.
    public init(report: AirBudget.Report) {
        let phrases = report.phrases.map {
            Phrase(startBeat: $0.startBeat, endBeat: $0.endBeat,
                   airAtStart: $0.airAtStart, airAtEnd: $0.airAtEnd,
                   lowestAir: $0.lowestAir, exhausted: $0.exhausted,
                   constrainedNoteCount: $0.constrainedNotes.count)
        }
        var marks: [BreathMark] = []
        marks.reserveCapacity(report.phrases.count)
        for phrase in report.phrases {
            switch phrase.breath {
            case .none:
                continue
            case let .taken(beat, seconds):
                marks.append(BreathMark(beat: beat, seconds: seconds, taken: true))
            case let .tooShort(beat, seconds):
                marks.append(BreathMark(beat: beat, seconds: seconds, taken: false))
            }
        }
        self.init(phrases: phrases,
                  breaths: marks,
                  startBeat: phrases.first?.startBeat ?? 0,
                  endBeat: phrases.last?.endBeat ?? 0,
                  applied: report.applied,
                  constrainedNoteCount: report.constrainedNoteCount,
                  notesConsidered: report.notesConsidered,
                  maxAttenuationDb: report.maxAttenuationDb,
                  lowestAir: report.lowestAir,
                  neverRecovered: report.neverRecovered,
                  hasReport: true)
    }

    /// Is there anything to draw?
    public var isDrawable: Bool { hasReport && endBeat > startBeat && !phrases.isEmpty }

    /// The 0…1 x position of a beat inside the strip.
    public func position(ofBeat beat: Double) -> Double {
        guard endBeat > startBeat else { return 0 }
        return min(1, max(0, (beat - startBeat) / (endBeat - startBeat)))
    }

    /// **The sentence the panel prints.** Tense follows `applied`, always.
    ///
    /// This is design §9.4 layer 2 in the panel: the existence of the effect is
    /// never silent, and a counterfactual is never reported as a fact.
    public var headline: String {
        guard hasReport else {
            return "Apply the shape to see how the player's air held up."
        }
        guard constrainedNoteCount > 0 else {
            return applied
                ? "Air enforcement is on and no note ran short — nothing was pulled down."
                : "No note runs short of air, so enforcing it would change nothing."
        }
        let db = String(format: "%.1f", maxAttenuationDb)
        if applied {
            return "Air enforcement pulled \(constrainedNoteCount) of \(notesConsidered) "
                + "notes down, by up to \(db) dB."
        }
        return "AIR IS OFF. Enforcing it WOULD pull \(constrainedNoteCount) of "
            + "\(notesConsidered) notes down, by up to \(db) dB."
    }

    /// The second line, when the part never gets its breath back. Its fix is
    /// different from every other one here, which is why it is its own sentence.
    public var recoveryNote: String? {
        guard hasReport, neverRecovered else { return nil }
        return "The rests in this part are too short for the player to recover — "
            + "the sag builds up instead of resetting. Write a longer rest, or raise the refill rate."
    }
}

// MARK: - The model

/// Headless state machine for the BREATH PAD (m28-p7): a circle of effort
/// gestures, a dot the hand moves between them, a live preview while the
/// gesture is open, and ONE commit when it is released.
///
/// The user's words are the spec: *"controller with big circular knob where the
/// dot is moving between different patterns that are placed around the circle…
/// we need to mimic human playing to the max."*
///
/// All the logic is here and none of it is in the view — the
/// `HumanizeModel` / `QuantizeModel` precedent. The model never touches a store:
/// it calls injected closures wired to `ProjectStore.applyEffortShape` and
/// `ProjectStore.previewEffort`, which are the SAME methods the
/// `clip.applyEffortShape` and `pad.previewEffort` wire verbs use. One mutation
/// path, never a parallel one — and no new wire surface (the m10-c/sp-b
/// pure-view rule: `allCommands` and MCP are untouched).
///
/// ## ⛔⛔ THE PAD NEVER STREAMS UNLESS A GESTURE IS IN PROGRESS
///
/// Design §5.2, restated so it cannot be got wrong: streaming happens **if and
/// only if** a gesture is open. With no gesture, what you hear is the committed
/// lane and nothing else, so playback, replay and a bounce agree sample for
/// sample. `setDot` outside a gesture moves the dot and pushes nothing.
///
/// The rate cap has exactly ONE home and it is not this file:
/// `PadPreviewController` caps at 30 Hz, filters unchanged values and releases
/// to neutral on `.end`. This model calls `preview` on the moves it receives and
/// lets that policy do its job — a second throttle here would be a second place
/// for the two to disagree.
///
/// ## The commit is on RELEASE, once, and only if the dot MOVED
///
/// `applyEffortShape` spends an undo step and rebuilds the clip's controller
/// lanes, which restarts playback with a mid-decay note re-attack. Committing
/// per drag frame would pay that per frame — the m25-k shape, where *a correct
/// policy at the wrong cadence looks exactly like a correct policy*, and undo
/// coalescing cannot see it. The movement gate is `DeferredKnob`'s part 3
/// verbatim: a plain click is a complete drag with zero translation, and an
/// ungated release would make every stray press on the pad spend an edit.
///
/// ## The gesture API is not a pointer API
///
/// `beginGesture` / `setDot` / `endGesture` take no points. The pointer path is
/// a thin adapter (`beginDrag(at:geometry:)` and friends) that converts through
/// `BreathPadGeometry`. A hardware knob (m28-knob) holds one gesture open across
/// many value changes with no pointer at all, and an angle/radius pair is
/// exactly what two knobs produce — so that extension adds an adapter, not a
/// second state machine.
///
/// ## Colour and density
///
/// NO VIOLET anywhere: the pad is a performance control, not AI-generated
/// content (docs/DESIGN-LANGUAGE.md Rule 3 — violet is AI identity only). Cyan
/// marks earned active state (the dot under the hand, the SF Mono readouts);
/// amber marks the air warning, never red — §9.6 guarantees the budget can never
/// silence a note, so a destructive colour would overstate it. **No Simple/Pro
/// chip**: the panel is the same circle and the same switch in both densities,
/// and a toggle whose modes coincide is the do-nothing control the design
/// language forbids.
@MainActor
@Observable
public final class BreathPadModel {

    // MARK: - Injected providers

    /// Commits the dot into the clip's controller lanes — wired to
    /// `ProjectStore.applyEffortShape(clipID:ring:angleRadians:radius:air:)`,
    /// ONE `performEdit("Effort Shape")` undo step. A recorder in tests.
    public typealias Apply = (UUID, EffortRing, Double, Double, AirBudget.Settings)
        throws -> EffortShapeApplication
    /// Streams one effort value for as long as a gesture is open — wired, since
    /// m34-f step ②, to `LiveExpressionSink.setExpression(trackID:effort:phase:)`
    /// and through it to `ProjectStore.playLiveExpression`.
    ///
    /// ⚠️ **THE ANSWER IS RETURNED, NOT DISCARDED, AND THAT IS THE POINT.** It
    /// carries the engine's own verdict on whether this push reached a rolling
    /// take (`PadPreviewResult.recording`). A pad that could only say *"I sent
    /// it"* would agree with itself through a dead pipe — the m23-o2
    /// `widthSource` failure in another medium. `nil` is legal and means *this
    /// closure has no answer* (a recorder in a test), which is a third state and
    /// deliberately not folded into "not recording".
    public typealias Preview = (UUID, Double, PadPreviewPhase) throws -> PadPreviewResult?

    private let applyClosure: Apply
    private let previewClosure: Preview

    public init(apply: @escaping Apply, preview: @escaping Preview) {
        self.applyClosure = apply
        self.previewClosure = preview
    }

    // MARK: - Target

    /// The clip the commit writes into; nil until `prepare`.
    public private(set) var targetClipID: UUID?
    /// The track the PREVIEW streams to. A commit needs a clip and a preview
    /// needs a track, and they are not the same identifier — carrying only one
    /// is how a panel ends up with a working apply and a silent drag.
    public private(set) var targetTrackID: UUID?
    public private(set) var targetClipName: String = ""
    /// MIDI-only, matching `applyEffortShape`, which has no notes to shape on an
    /// audio clip.
    public private(set) var targetIsMIDI: Bool = true

    /// Points the pad at a clip. **The dot is KEPT across `prepare`** (the
    /// `QuantizeModel`/`HumanizeModel` sticky-amounts idiom): a player who found
    /// a gesture they like should get it again on the next phrase. Everything
    /// that describes the LAST clip — the report, the warnings, the refusals —
    /// is cleared unconditionally, including to nil, because a report that
    /// survived an open on another clip would read as a fresh one.
    public func prepare(clipID: UUID, trackID: UUID, clipName: String, isMIDI: Bool) {
        endGestureWithoutCommitting()
        targetClipID = clipID
        targetTrackID = trackID
        targetClipName = clipName
        targetIsMIDI = isMIDI
        lastApplication = nil
        gauge = .unknown
        warnings = []
        applyRefusal = nil
        previewRefusal = nil
        trail.clear()
    }

    /// Forgets the target entirely (the panel closed).
    public func clear() {
        endGestureWithoutCommitting()
        targetClipID = nil
        targetTrackID = nil
        targetClipName = ""
        lastApplication = nil
        gauge = .unknown
        warnings = []
        applyRefusal = nil
        previewRefusal = nil
        trail.clear()
    }

    // MARK: - The ring and the dot

    /// The eight gestures, in ring order — index 0 at the top, clockwise.
    public private(set) var ring: EffortRing = .standard

    /// Where the hand put the dot. Angle in radians (wrapped), radius 0…1.
    public private(set) var dot: DotPosition = DotPosition(angle: 0, radius: 1)

    /// The gesture in flight, or nil. **The one condition under which anything
    /// streams.**
    public private(set) var gesture: GestureSource?

    /// Where the dot was when the gesture began — the movement gate's reference.
    private var gestureStartDot: DotPosition?

    /// The trail the view draws while a gesture is open.
    public private(set) var trail = BreathPadTrail()

    /// Who is moving the dot. The pointer today; a mapped hardware knob
    /// (m28-knob) tomorrow — the model does not care, and that is the point.
    public enum GestureSource: String, Sendable, Equatable, CaseIterable {
        case pointer
        case external
    }

    /// How far the dot must move for a release to count as an edit. In dot
    /// units: an angle of one degree, or a radius of a hundredth.
    ///
    /// `nonisolated`, with `moved` below, so the movement gate — the rule that
    /// decides whether a release spends an undo step — can be asserted from a
    /// free (non-`@MainActor`) suite. The tree is at its 330-`@MainActor`-suite
    /// ceiling, and a rule this load-bearing should not have to buy a slot.
    nonisolated public static let movementEpsilon = 0.01

    // MARK: - Air

    /// **The switch design §9.5 requires to be prominent.** `enforced` defaults
    /// to FALSE by user ruling: an air budget overrides what the composer wrote,
    /// so it is opted into once, visibly. The panel puts it on the face of the
    /// card, not behind a disclosure.
    public var airEnforced: Bool = AirBudget.Settings.standard.enforced

    /// Everything else about the budget stays at the DAWCore defaults. The panel
    /// asks one question a musician can answer ("should he run out of air?");
    /// `consumptionExponent` is an expert question and a slider whose meaning has
    /// to be explained before it can be moved is a do-nothing control. An agent
    /// that needs those knobs has them on `clip.applyEffortShape`.
    public var airSettings: AirBudget.Settings {
        var s = AirBudget.Settings.standard
        s.enforced = airEnforced
        return s
    }

    // MARK: - Results

    /// What the last commit did. nil before the first one.
    public private(set) var lastApplication: EffortShapeApplication?
    /// The air report, in the form the strip draws. `.unknown` before the first
    /// commit — which the headline says out loud rather than drawing an empty
    /// strip that could be read as "all clear".
    public private(set) var gauge: BreathPadAirGauge = .unknown
    /// The store's own warning sentences, VERBATIM. They already carry the
    /// measured facts (which controller moves what on which instrument kind, and
    /// which of bounce or live a sampling ceiling refers to); re-wording them
    /// here is how a UI ends up promising something the engine does not do.
    public private(set) var warnings: [String] = []
    /// Why the last commit did not happen.
    public private(set) var applyRefusal: String?
    /// Why the live preview is not being heard. Surfaced rather than swallowed:
    /// the live-expression path refuses on a non-instrument track, and a pad
    /// that silently does nothing is indistinguishable from a broken one.
    ///
    /// ⚠️ **"AND WHILE RECORDING" WAS TRUE UNTIL m34-f AND IS NOW FALSE** — the
    /// pad streams THROUGH a take and is captured into it. The retraction is
    /// written here rather than the old clause quietly deleted: a stale *"this
    /// cannot be done"* comment is the class of thing that froze four roadmap
    /// items in this repo for eight days.
    public private(set) var previewRefusal: String?

    /// ⭐ **THE HONESTY LIGHT (m34-f step ②) — playing vs recording.** The
    /// ENGINE's answer to *"is what I am shaping being kept?"*, off the last
    /// push. `nil` means nothing has been pushed this gesture, or the closure
    /// under the seam has no answer to give; it is deliberately NOT folded into
    /// `false`, because "I do not know" and "it is not being recorded" are
    /// different things to put on screen.
    public private(set) var isCapturingExpression: Bool?
    /// Controller points this GESTURE has put into the take so far — the
    /// running total the readout shows, so a user can see the count climb
    /// rather than trust a lamp. Reset at every `begin`.
    public private(set) var capturedExpressionPoints = 0

    /// What the VIEW was given and what it DREW — written by the panel, read by
    /// the debug echo, consulted by NOTHING.
    ///
    /// ⭐ **Why a view reports back at all.** Three defects in this card's height
    /// budget have been found by capturing a PNG and inferring the geometry from
    /// it, and the third did not converge: the card's measured height, the dial's
    /// measured diameter and the window's height each implied a different
    /// `available`, and no combination of them was consistent. Pixels can say the
    /// card is 857 pt tall; only the view can say what it was offered. `overhang`
    /// is then a subtraction rather than an argument.
    ///
    /// ⛔ **The layout must never read this.** A budget that consumed its own
    /// measurement would converge on whatever it drew last and the discrepancy
    /// would disappear into the feedback loop — the shape of every "the setter
    /// returned, so it took" mistake in this tree.
    public var measuredLayout = MeasuredLayout()

    /// ⭐ **A COUNTER, NOT A FLAG — the card's scroller watches it and jumps to
    /// the bottom when it changes.**
    ///
    /// This exists because of a measured dead end: with the hardware section
    /// expanded, the pad's card is taller than the tallest window this display
    /// can grant (971.5 pt of card against 934 pt of room at `available` 982), so
    /// the section is ALWAYS below the fold and no capture can show it. The probe
    /// happily logged "captured: the WHOLE expanded section, unclipped" while
    /// photographing the part of the card the section is not in — a green check
    /// on an image of an absence, which is this tree's characteristic failure.
    ///
    /// A counter rather than a `Bool` so two consecutive requests both fire;
    /// `onChange` on a flag already set is silent, which would make the
    /// instrument work once per launch and then quietly stop.
    ///
    /// ⚠️ Drives NO layout. It moves a scroll offset and nothing else.
    public var scrollToBottomRequest = 0

    /// The panel's own account of its layout. Points.
    public struct MeasuredLayout: Sendable, Equatable {
        /// The height the card's `GeometryReader` was offered.
        public var available: CGFloat = 0
        /// The height the card actually drew at.
        public var cardHeight: CGFloat = 0
        /// The height the HARDWARE section drew at, collapsed or expanded
        /// (m28-knob-ui).
        ///
        /// ⭐ **Why a SECOND report, when the card already reports itself.**
        /// `hardwareExpandedChrome` is a DIFFERENCE between two card heights,
        /// and the card cannot supply it: on a short display the expanded card
        /// hits the scroll cascade and is CLAMPED to its room, so the difference
        /// between the two drawn cards is whatever the clamp left over — 21.5 pt
        /// in the first measurement, against a section that is an order of
        /// magnitude taller than that. A clamped reading looks exactly like a
        /// real one. The section reports its OWN height, which is natural in
        /// both states (a `ScrollView`'s content is not clamped), so the
        /// subtraction is honest at any window size.
        public var hardwareHeight: CGFloat = 0
        public init(available: CGFloat = 0, cardHeight: CGFloat = 0,
                    hardwareHeight: CGFloat = 0) {
            self.available = available
            self.cardHeight = cardHeight
            self.hardwareHeight = hardwareHeight
        }

        /// How far the card exceeds the room the margin leaves it — 0 when it
        /// fits. Positive means the card is eating into (or past) the window
        /// margin, split evenly top and bottom because the card is centred.
        public var overhang: CGFloat {
            guard available > 0 else { return 0 }
            return max(0, cardHeight - (available - BreathPadLayout.windowMargin * 2))
        }
    }

    // MARK: - Gesture lifecycle (source-independent)

    /// Opens a gesture. From here until `endGesture`, and only here, the dot
    /// streams.
    public func beginGesture(source: GestureSource = .pointer) {
        guard targetTrackID != nil || targetClipID != nil else { return }
        gesture = source
        gestureStartDot = dot
        previewRefusal = nil
        // ⛔ **THE PRESSURE LATCH IS PER-GESTURE, NOT PER-SESSION.** A finger
        // that lifted is a finger applying no force, and carrying the last
        // gesture's pressure into the next one would open it at whatever force
        // the user happened to release at. `pressureObserved` (the CAPABILITY
        // fact) deliberately does NOT reset — hardware does not stop being
        // Force Touch between gestures.
        pressure = nil
        trail.clear()
        trail.record(dot)
        stream(phase: .begin)
    }

    // MARK: - Pressure (m34-f step ①)

    /// The force currently on the pad, 0…1, or `nil` when none has been
    /// observed THIS GESTURE.
    ///
    /// ⚠️ **`nil` IS NOT `0`.** It means "this machine has told us nothing about
    /// force", which is the permanent state on a mouse or a non-Force-Touch
    /// trackpad, and the state at the very start of every gesture until the
    /// first pressure event lands. In that state the pad streams the dot's
    /// effort alone — bit-for-bit what it streamed before this axis existed.
    public private(set) var pressure: Double?

    /// ⭐ **OBSERVED capability, never queried capability.** True once a real
    /// `NSEventTypePressure` event has reached this model in this session — a
    /// thing only a Force Touch trackpad emits. There is no verified public API
    /// that answers "does this Mac have one" from inside a running app, so the
    /// UI is driven by what actually happened rather than by a claim.
    ///
    /// ⛔ **NOTHING ON SCREEN MAY ANNOUNCE A PRESSURE AXIS UNTIL THIS IS TRUE.**
    /// A pad that looks pressure-capable on a machine that cannot produce
    /// pressure is a control that lies about what it does — and the user would
    /// have no way to tell that from a control that is simply broken.
    public private(set) var pressureObserved = false

    /// A real pressure event arrived. Re-streams immediately at the new value,
    /// because pressure is the fastest-moving of the three axes and waiting for
    /// the next pointer move would make a swell lag the hand.
    ///
    /// ⚠️ **STREAMS AS `.move`, WHICH MEANS IT IS RATE-CAPPED AND
    /// CHANGE-FILTERED, AND THAT IS CORRECT.** Trackpad pressure updates far
    /// faster than 30 Hz and a dropped intermediate value is inaudible; a STUCK
    /// last value would not be. `PadPreviewController` guarantees the last value
    /// of a gesture is always delivered because `.end` bypasses the cap, so the
    /// stream can never strand the strip at a pressure the finger has left.
    ///
    /// Ignored when no gesture is open: pressure without a click is not a thing
    /// this surface can receive, and treating it as one would stream while the
    /// transport merely rolls — the rule the whole gesture machine exists for.
    public func pressureChanged(_ value: Double) {
        pressureObserved = true
        guard gesture != nil else { return }
        pressure = PadPressure.clamp(value)
        stream(phase: .move)
    }

    /// Moves the dot. Streams only if a gesture is open.
    public func setDot(angle: Double, radius: Double) {
        dot = DotPosition(angle: EffortRing.wrap(angle), radius: radius)
        guard gesture != nil else { return }
        trail.record(dot)
        stream(phase: .move)
    }

    /// Releases: stops streaming, then commits ONCE if the dot moved.
    /// Returns whether a commit fired — the `HumanizeModel.apply` contract, so
    /// the view can close on a real edit and stay open on a refusal.
    @discardableResult
    public func endGesture() -> Bool {
        guard gesture != nil else { return false }
        let moved = gestureMoved
        // ⚠️ ORDER IS LOAD-BEARING: the preview is released to neutral BEFORE
        // the commit rebuilds the lane. The other order leaves a preview value
        // parked on the strip across a schedule rebuild, which is exactly the
        // state `PadPreviewController`'s rule 3 exists to prevent.
        stream(phase: .end)
        gesture = nil
        gestureStartDot = nil
        // AFTER the stream, never before: `.end` restores neutral and does not
        // read the value, but a reader of `streamedEffort` at rest must see the
        // dot alone rather than the force of a finger that has lifted.
        pressure = nil
        trail.clear()
        guard moved else { return false }
        return commit()
    }

    /// The panel closed, the app resigned, a project boundary crossed: end the
    /// stream and commit NOTHING. A gesture abandoned by a dismissal did not ask
    /// for an edit.
    public func endGestureWithoutCommitting() {
        guard gesture != nil else { return }
        stream(phase: .end)
        gesture = nil
        gestureStartDot = nil
        pressure = nil
        trail.clear()
    }

    /// Did the dot travel far enough for the release to be an edit?
    public var gestureMoved: Bool {
        guard let start = gestureStartDot else { return false }
        return Self.moved(from: start, to: dot)
    }

    /// The movement test, pure so it can be asserted directly. Angle is compared
    /// on the SHORT way round, so a dot dragged across the 0/2π seam does not
    /// read as a full turn.
    nonisolated public static func moved(from a: DotPosition, to b: DotPosition) -> Bool {
        if abs(a.radius - b.radius) > movementEpsilon { return true }
        var d = abs(EffortRing.wrap(a.angle) - EffortRing.wrap(b.angle))
        if d > .pi { d = 2 * .pi - d }
        return d > movementEpsilon
    }

    // MARK: - Pointer adapter

    /// A press in the pad. Three cases, resolved in ONE gesture so there is
    /// exactly one commit path:
    ///
    /// - on the DOT: grab it, leave it where it is;
    /// - on a pattern's NAME: park the dot exactly on that gesture (§8.2 — being
    ///   able to select one pattern exactly is the whole point of the circle),
    ///   at full radius if the dot was sitting in the dead centre, because a
    ///   press on a name that visibly did nothing would be a broken affordance;
    /// - anywhere else: JUMP the dot to the press, so the gesture always starts
    ///   under the finger.
    public func beginDrag(at point: CGPoint, geometry: BreathPadGeometry) {
        let grabbed = geometry.isOnDot(point, dot: dot)
        let named = geometry.patternHit(point, count: ring.count)
        beginGesture(source: .pointer)
        if let named {
            setDot(angle: ring.angle(ofIndex: named),
                   radius: dot.radius > 0 ? dot.radius : 1)
        } else if !grabbed {
            let target = geometry.dot(at: point)
            setDot(angle: target.angle, radius: target.radius)
        }
    }

    public func drag(to point: CGPoint, geometry: BreathPadGeometry) {
        let target = geometry.dot(at: point)
        setDot(angle: target.angle, radius: target.radius)
    }

    @discardableResult
    public func endDrag() -> Bool { endGesture() }

    // MARK: - On-screen precision knobs (m28-knob-ui)

    /// The dot's angle as a knob travel fraction, 0…1 → one full turn of the
    /// ring. **Both ends land on ring index 0**, which is what a circle does.
    ///
    /// ⚠️ **The knob is fed THIS, and `knobMoved` compares against THIS.** The
    /// round trip fraction → radians → fraction is not bit-exact in floating
    /// point, so comparing the resulting DOT would make a zero-movement tick
    /// look like a move roughly whenever the last bit disagreed. Comparing the
    /// fractions is exact, because it is the same expression on both sides.
    public var angleFraction: Double { EffortRing.wrap(dot.angle) / (2 * .pi) }

    /// The dot's depth as a knob travel fraction — already 0…1.
    public var radiusFraction: Double { dot.radius }

    /// A precision knob moved. Pass ONE axis; the other stays where it is.
    ///
    /// ## ⛔ WHY THE "DID IT ACTUALLY CHANGE" GUARD IS LOAD-BEARING
    ///
    /// `KnobControl`'s gesture is `DragGesture(minimumDistance: 0)`, so a plain
    /// CLICK on the cap is a complete drag with zero translation: `onChange`
    /// fires once with the value it already had, and `onCommit` — which fires
    /// only if the drag MOVED — never fires at all. A version of this that
    /// opened a gesture on every `onChange` would open one that nothing ever
    /// closes, leaving a live controller preview parked on the instrument until
    /// `PadPreviewController`'s 30 s ceiling fired. That is precisely the state
    /// rule 3 exists to prevent, and a stray click is not a rare input.
    ///
    /// So the gesture opens only on a tick that genuinely changes the dot. That
    /// makes **"we opened a gesture" and "`onCommit` will fire" the same
    /// condition**, which is provable rather than hopeful: `KnobControl` latches
    /// `dragMovedValue` on `next != start`, `start` is the fraction the knob was
    /// handed, and before we open, that fraction IS `angleFraction` /
    /// `radiusFraction`. One predicate, two places.
    ///
    /// The source is `.pointer` and not a third case, so the existing
    /// "THE POINTER WINS" precedence in `pumpExternalControl` covers a hand on
    /// the knob and a hand on the hardware with no new rule.
    ///
    /// Returns whether the dot moved — for tests, and so a caller can tell a
    /// real tick from the stray-click case.
    @discardableResult
    public func knobMoved(angleFraction newAngle: Double? = nil,
                          radiusFraction newRadius: Double? = nil) -> Bool {
        let angleChanged = newAngle.map { $0 != angleFraction } ?? false
        let radiusChanged = newRadius.map { $0 != radiusFraction } ?? false
        if gesture == nil {
            guard angleChanged || radiusChanged else { return false }
            beginGesture(source: .pointer)
        }
        setDot(angle: newAngle.map { $0 * 2 * .pi } ?? dot.angle,
               radius: (newRadius ?? dot.radius).clamped(to: 0...1))
        return true
    }

    /// The knob was released. Ends the gesture exactly as the dial's release
    /// does — committing only if the dot travelled past `movementEpsilon`, which
    /// is the pad's own movement gate and not the knob's.
    @discardableResult
    public func knobReleased() -> Bool { endGesture() }

    /// Double-click on the ANGLE knob: back to the top of the ring.
    ///
    /// ⛔ **ONE KNOB RESETS ONE AXIS.** The first version of this was a single
    /// `resetKnobs()` wired to both `onReset` closures, so double-clicking DEPTH
    /// swung the ANGLE too — a control silently moving a parameter it does not
    /// name. Every other knob in the app (`KnobControl.onReset`, `DeferredKnob`)
    /// resets its own value and nothing else, and a panel is not the place to
    /// break that contract. The coupled version also had a TEST asserting it,
    /// which is how a defect gets certified rather than caught.
    ///
    /// It moves the dot and **commits nothing**: a reset is a re-aim, not an
    /// edit, and WRITE THE SHAPE is one press away.
    public func resetAngle() {
        endGestureWithoutCommitting()
        setDot(angle: 0, radius: dot.radius)
    }

    /// Double-click on the DEPTH knob: back to full strength.
    ///
    /// ⚠️ Deliberately **1, not 0**. Radius 0 is the "exactly as written" no-op
    /// where `canApply` turns off — a double-click that silently disabled the
    /// apply button would read as a broken panel, not as a reset.
    public func resetDepth() {
        endGestureWithoutCommitting()
        setDot(angle: dot.angle, radius: 1)
    }

    // MARK: - Hardware-knob adapter (m28-knob)

    /// How many pump passes with NO controller movement end an external
    /// gesture. The feed runs at ~30 Hz (`MIDIInputManager`'s drain), so 15
    /// passes is ≈ **0.5 s** of a still knob.
    ///
    /// A COUNT and not a wall-clock duration, deliberately: the pump is the only
    /// clock this path has, counting it is exact, and a test drives the rule by
    /// calling the pump rather than by sleeping. A timeout asserted with a sleep
    /// is a flake with a schedule.
    nonisolated public static let externalIdlePasses = 15

    /// Pump passes since the knob last moved. Only meaningful while an
    /// `.external` gesture is open.
    public private(set) var externalIdleCount = 0

    /// ⛔⛔ **THE KNOB DOES NOT COMMIT, AND THAT IS THE DESIGN — NOT A GAP.**
    ///
    /// An external gesture ends with `endGestureWithoutCommitting()`: the
    /// preview releases to neutral (rule 3), the dot stays exactly where the
    /// knob left it, and **no undo step is spent**. The APPLY button (or
    /// `commit()`, which is public for precisely this reason) writes the shape.
    ///
    /// The alternative — committing when the knob goes quiet — is the m25-k
    /// shape wearing a new hat. `applyEffortShape` spends an undo step and
    /// rebuilds the clip's controller lanes, restarting playback with a
    /// mid-decay re-attack. A mouse drag pays that ONCE because a hand releases
    /// once; a knob ride is PAUSE-HEAVY, so "commit on idle" pays it once per
    /// pause — a number the player never chose, cannot see, and would find in
    /// their undo history as a wall of identical entries. *A correct policy at
    /// the wrong cadence looks exactly like a correct policy.*
    ///
    /// `theKnobRideSpendsNoUndoSteps` holds this: a synthetic ride with three
    /// pauses must leave `applyCount` at 0.
    public func pumpExternalControl(_ pump: MIDIControlPump) {
        // The feed died under us (last binding removed mid-turn, engine gone).
        // Release now — the idle tick we are counting towards is not coming.
        if pump.feedEnded {
            if gesture == .external { endExternalGesture() }
            return
        }
        // ⚠️ THE POINTER WINS. A hand on the pad and a hand on the knob is two
        // sources for one dot; the one that opened the gesture keeps it, and the
        // other is ignored until it closes. Silently interleaving them would
        // make the dot jump between two positions at 30 Hz.
        if gesture == .pointer { return }

        // Coalesce: two values for one target in one 33 ms pass are a knob
        // mid-turn, not two moves. One `setDot` per pass means one preview push
        // per pass, which is the rate `PadPreviewController` is built for.
        var angle: Double?
        var radius: Double?
        for update in pump.updates {
            switch update.target {
            case .breathPadAngle: angle = update.value
            case .breathPadRadius: radius = update.value
            }
        }

        guard angle != nil || radius != nil else {
            guard gesture == .external else { return }
            externalIdleCount += 1
            if externalIdleCount >= Self.externalIdlePasses { endExternalGesture() }
            return
        }

        externalIdleCount = 0
        if gesture == nil { beginGesture(source: .external) }
        // A knob sweep of 0…1 is a full turn of the ring. **Both ends land on
        // ring index 0** — that is what a circle does, and it is why the ends of
        // the sweep are not wasted travel.
        setDot(angle: angle.map { $0 * 2 * .pi } ?? dot.angle,
               radius: radius ?? dot.radius)
    }

    /// Releases an external gesture without committing. Safe to call when none
    /// is open. Public so a panel dismissal or an app resignation can park the
    /// knob's gesture the same way it parks the pointer's.
    public func endExternalGesture() {
        externalIdleCount = 0
        guard gesture == .external else { return }
        endGestureWithoutCommitting()
    }

    // MARK: - Preview

    /// The effort the dot represents, 0…1 — what the drag streams.
    ///
    /// It is `EffortField`'s own top-level field law with no note and no phrase,
    /// which the field defines as the midpoint of both (`EffortField.effort`'s
    /// documented 0.5 fallback). The constant lives in DAWCore and is not
    /// restated here. The pad sets no `DotPath`, so `atBeat` is immaterial —
    /// `.fixed` leaves the dot on its origin at every beat.
    ///
    /// ⚠️ **MEASURED SPAN, so nobody has to wonder whether this control does
    /// anything:** across the eight library patterns at radius 1 this reads
    /// 0.499 (late bloom) … 1.000 (messa di voce), i.e. **CC 63 … 127**, and a
    /// radius sweep on hairpin diminuendo runs 127 → 79. On the hosted-AU path
    /// CC 11 is a square-law gain, so CC 63 against 127 is about −12 dB —
    /// audible, not a dead knob. It also never reaches 0: the pad cannot preview
    /// a silence, which matches §9.6's promise about the budget.
    ///
    /// ⚠️ **THAT LAST SENTENCE IS STILL TRUE OF THIS PROPERTY AND IS NO LONGER
    /// TRUE OF WHAT THE PAD STREAMS (m34-f step ①).** `streamedEffort` scales
    /// this by trackpad pressure, and pressure genuinely reaches 0. The claim is
    /// narrowed rather than deleted, because it is still the right thing to know
    /// about the DOT — see `PadPressure` for why a silent full-release is the
    /// feature and not a regression.
    public var effort: Double {
        EffortField.effort(atBeat: 0, settings: fieldSettings)
    }

    /// ⭐ **WHAT ACTUALLY GOES OUT — the dot's effort scaled by pressure**
    /// (m34-f step ①). Identical to `effort` whenever no pressure has been
    /// observed, which is every mouse, every non-Force-Touch trackpad, and the
    /// opening instant of every gesture. `PadPressure` owns the law and the
    /// rationale; nothing is restated here.
    public var streamedEffort: Double {
        PadPressure.effort(dotEffort: effort, pressure: pressure)
    }

    /// The dot resolved: which patterns are sounding and how much of each.
    public var blend: EffortRing.Blend {
        ring.blend(atAngle: dot.angle, radius: dot.radius)
    }

    private var fieldSettings: EffortField.Settings {
        EffortField.Settings(ring: ring, origin: dot, path: .fixed)
    }

    /// The one place a preview call is made. Silent when there is no track —
    /// a clip can be shaped without an instrument to hear it on.
    private func stream(phase: PadPreviewPhase) {
        guard let trackID = targetTrackID else { return }
        if phase == .begin {
            capturedExpressionPoints = 0
            isCapturingExpression = nil
        }
        do {
            let result = try previewClosure(trackID, streamedEffort, phase)
            if let result {
                capturedExpressionPoints += result.capturedPoints
                // ⛔⛔ **ONLY A DELIVERED CALL CARRIES AN ANSWER, AND THIS LINE
                // IS A MEASURED BUG FIX RATHER THAN A PRECAUTION.** A `.move`
                // that the 30 Hz cap or the unchanged-value filter coalesced
                // away never reached the engine, so its `recording: false` means
                // *"nothing was asked"*, not *"nothing is being kept"*. Letting
                // it through made the INTO TAKE lamp flicker off on the very
                // next drag frame — caught by CAPTURING THE PANEL and reading
                // the state beside it (`capturedExpressionPoints: 1` while
                // `isCapturingExpression: false`, which cannot both be current).
                // A coalesced frame now leaves the last real answer standing.
                if result.delivered { isCapturingExpression = result.recording }
            }
            if phase != .end { previewRefusal = nil }
        } catch {
            // A refused `.end` is not worth reporting — nothing was streaming.
            if phase != .end {
                previewRefusal = (error as? ProjectError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Commit

    /// Whether a commit could fire at all. A radius of 0 is a TRUE no-op: the
    /// blend collapses to `neutral`, which is "exactly as authored", so the call
    /// would spend an undo step to write the part it already has.
    public var canApply: Bool {
        targetClipID != nil && targetIsMIDI && dot.radius > 0
    }

    /// Applies the dot through the injected closure. Public because the panel's
    /// APPLY button is a second, equal route to the same edit — a human who
    /// nudged the dot with the keyboard, or who wants to re-run it with the air
    /// switch flipped, must not have to fake a drag.
    @discardableResult
    public func commit() -> Bool {
        guard canApply, let clipID = targetClipID else {
            applyRefusal = dot.radius > 0
                ? nil
                : "The dot is in the middle, which means \"exactly as written\" — "
                    + "drag it outwards to shape the part."
            return false
        }
        do {
            let result = try applyClosure(clipID, ring, dot.angle, dot.radius, airSettings)
            lastApplication = result
            gauge = BreathPadAirGauge(report: result.air)
            warnings = result.warnings
            applyRefusal = nil
            return true
        } catch {
            applyRefusal = (error as? ProjectError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Readouts (SF Mono in the view)

    /// `"142°"` — where the dot points.
    public var angleReadout: String {
        String(format: "%.0f°", EffortRing.degrees(fromRadians: dot.angle))
    }

    /// `"0.72"` — how far out. Called DEPTH in the panel, never "level": at
    /// radius 0 the blend collapses to `EffortRing.defaultNeutral` (1 — "exactly
    /// as authored"), which is the LOUDEST reading, not the quietest. A label
    /// implying the centre is quiet would be backwards.
    public var radiusReadout: String { String(format: "%.2f", dot.radius) }

    /// `"0.62 · CC 79"` — the effort the drag is streaming, and the expression
    /// value it becomes. The CC integer is `PadPreviewController`'s own mapping,
    /// not a second one.
    ///
    /// ⚠️ **READS `streamedEffort`, NOT `effort` (m34-f step ①).** The readout's
    /// whole job is to say what is going out; showing the dot's unscaled effort
    /// while pressure attenuated it would be a number that disagrees with the
    /// sound, which is the worst kind of readout to ship.
    public var effortReadout: String {
        String(format: "%.2f · CC %d", streamedEffort,
               PadPreviewController.controllerValue(forEffort: streamedEffort))
    }

    /// `"0.48"` — the force on the pad right now, or nil when there is none to
    /// report. **nil renders NOTHING**: no row, no dash, no zero. A readout that
    /// showed `0.00` on a mouse would be reporting a constant as a measurement.
    public var pressureReadout: String? {
        guard pressureObserved, let pressure else { return nil }
        return String(format: "%.2f", pressure)
    }

    /// `"MESSA DI VOCE 68% · LATE BLOOM 32%"` — which gestures the dot is
    /// actually blending, in ring order, with the minor member dropped below 1%
    /// so a dot parked on a pattern reads as that pattern alone.
    public var blendReadout: String {
        let members = blend.members
            .filter { $0.weight >= 0.005 }
            .sorted { $0.weight > $1.weight }
        guard !members.isEmpty else { return "" }
        return members
            .map { "\($0.pattern.displayName.uppercased()) \(Int(($0.weight * 100).rounded()))%" }
            .joined(separator: " · ")
    }

    /// The dominant gesture's own one-line description, from DAWCore. The panel
    /// says what the dot MEANS and not only where it is
    /// (docs/DESIGN-LANGUAGE.md — beginner-readable labels).
    public var blendSummary: String { blend.dominant.pattern.summary }

    /// The pattern names in ring order — what the view draws around the circle.
    public var patternNames: [String] { ring.patterns.map(\.displayName) }

    /// Which ring index is nearest the dot, for the view's "you are here"
    /// highlight.
    public var nearestPatternIndex: Int { blend.dominant.index }
}
