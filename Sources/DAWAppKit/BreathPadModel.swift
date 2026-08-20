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
    public static let fixedChrome: CGFloat = 433
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

    /// What the card WANTS, before anything yields.
    public static func naturalHeight(hasWarnings: Bool, hasRecoveryNote: Bool) -> CGFloat {
        fixedChrome + dialCeiling
            + (hasWarnings ? warningsCeiling + warningsChrome : 0)
            + (hasRecoveryNote ? recoveryNoteHeight : 0)
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
                               hasRecoveryNote: Bool) -> (dial: CGFloat, warnings: CGFloat) {
        let room = available - windowMargin * 2
        var shortfall = naturalHeight(hasWarnings: hasWarnings,
                                      hasRecoveryNote: hasRecoveryNote) - room
        guard shortfall > 0 else { return (dialCeiling, warningsCeiling) }

        let dialGive = min(shortfall, dialCeiling - dialFloor)
        shortfall -= dialGive
        let warningsGive = hasWarnings ? min(shortfall, warningsCeiling - warningsFloor) : 0
        return (dialCeiling - dialGive, warningsCeiling - warningsGive)
    }

    /// The dial's drawn side — the common read.
    public static func dialSide(available: CGFloat, hasWarnings: Bool = false,
                                hasRecoveryNote: Bool = false) -> CGFloat {
        regions(available: available, hasWarnings: hasWarnings,
                hasRecoveryNote: hasRecoveryNote).dial
    }

    /// The warnings block's bound at this window.
    public static func warningsRoom(available: CGFloat, hasWarnings: Bool,
                                    hasRecoveryNote: Bool = false) -> CGFloat {
        regions(available: available, hasWarnings: hasWarnings,
                hasRecoveryNote: hasRecoveryNote).warnings
    }

    /// The smallest card the layout can produce — **derived from the floors**,
    /// so a floor can never outrank the ceiling the way m26-i's picked minimum
    /// did.
    public static func minimumCardHeight(hasWarnings: Bool = true,
                                         hasRecoveryNote: Bool = true) -> CGFloat {
        fixedChrome + dialFloor
            + (hasWarnings ? warningsFloor + warningsChrome : 0)
            + (hasRecoveryNote ? recoveryNoteHeight : 0)
    }

    /// The card's height at a given window, after both regions have yielded.
    public static func cardHeight(available: CGFloat, hasWarnings: Bool = false,
                                  hasRecoveryNote: Bool = false) -> CGFloat {
        let r = regions(available: available, hasWarnings: hasWarnings,
                        hasRecoveryNote: hasRecoveryNote)
        return fixedChrome + r.dial
            + (hasWarnings ? r.warnings + warningsChrome : 0)
            + (hasRecoveryNote ? recoveryNoteHeight : 0)
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
    /// Streams one effort value for as long as a gesture is open — wired to
    /// `ProjectStore.previewEffort(trackID:value:phase:)`.
    public typealias Preview = (UUID, Double, PadPreviewPhase) throws -> Void

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
    /// `previewEffort` refuses on a non-instrument track and while recording, and
    /// a pad that silently does nothing is indistinguishable from a broken one.
    public private(set) var previewRefusal: String?

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

    /// The panel's own account of its layout. Points.
    public struct MeasuredLayout: Sendable, Equatable {
        /// The height the card's `GeometryReader` was offered.
        public var available: CGFloat = 0
        /// The height the card actually drew at.
        public var cardHeight: CGFloat = 0
        public init(available: CGFloat = 0, cardHeight: CGFloat = 0) {
            self.available = available
            self.cardHeight = cardHeight
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
        trail.clear()
        trail.record(dot)
        stream(phase: .begin)
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
    public var effort: Double {
        EffortField.effort(atBeat: 0, settings: fieldSettings)
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
        do {
            try previewClosure(trackID, effort, phase)
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
    public var effortReadout: String {
        String(format: "%.2f · CC %d", effort,
               PadPreviewController.controllerValue(forEffort: effort))
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
