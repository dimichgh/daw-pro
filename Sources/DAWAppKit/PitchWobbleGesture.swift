import CoreGraphics
import Foundation
import DAWCore

// m23-ap C5a-4a — THE WOBBLE TOOL'S AND THE DOT'S GESTURE LOGIC, HEADLESS.
//
// Design: `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §4 (the door
// and the handle), §5 (width and speed, branch by branch), §6 (the first tick
// on a sung note), §9 (the readout), and **§18 (the addendum: it overrides the
// earlier sections where they differ)**; the natural-tuning amendment at §5.2;
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §4 (THE
// TOP-CENTRE DOT, with the user's own tip wording); and
// `docs/design/2026-09-25-natural-tuning.md` §3b (coupling, selection,
// double-click) and R24.
//
// Everything the Wobble tool and the dot compute between a press and a commit,
// as plain values and static functions: no SwiftUI, no store, no actor. The
// view (C5a-4b) feeds it pointer travel and the estimator's readings, draws
// what it returns, and hands `PitchWobbleSession.commit()` to the store.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE USER'S ANSWERS THIS FILE CARRIES (handoff db, 2026-09-24)
// ═══════════════════════════════════════════════════════════════════════════
//
//  * `vibrato-axis: x-speed` → `PitchWobbleGesture.layout = .sidewaysIsSpeed`.
//  * `wobble-swap: swap` → a sideways drag on the singer's own wobble hands it
//    over to a new one (§6), rather than refusing (§6.3 Alternative 3).
//  * `wobble-onset: same` → "keep the built default (onset 0, full size at
//    once)": a wobble this tool CREATES starts with onset 0
//    (`newWobbleOnsetSeconds`). D14's provisional `min(0.25, 0.3 × length)` is
//    superseded. An existing onset is kept.
//  * `dot: other` → the dot is the Wobble tool's knob at the note's top centre;
//    a click is one step bigger, ⌥-click one smaller, a drag is the tool. Its
//    tip states the keep as a share of how it was sung, in THE USER'S words
//    (`PitchWobbleCopy.dotTip…`). That amends §9.3's "never print a keep
//    percentage": the READOUT still never does; the dot's TIP does.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⭐ THE HANDOFF SEED: WHAT SHIPS, AND WHY (the §18.7 question C5a-4a decides)
// ═══════════════════════════════════════════════════════════════════════════
//
// §18.2 seeds the new wobble at `readDepth ÷ response(pitch)` and refuses where
// `response` is nil; §18.7 subtracts the detector's anchor lag from τ. Both
// correct the reading towards the TRUE voice. But the render does not play
// against the true voice: REPLACE is `− detected(t) + generated(t)`
// (`PitchCorrectionCurve`'s banner, "you cannot cancel what you have not
// measured"). So at the crossing tick:
//
//     before (keep 1):              heard = true(t)
//     after  (scales 0 + a sine):   heard = true(t) − detected(t) + G(t)
//     the jump:                     G(t) − detected(t)
//
// The jump is zero only when `G` IS the wobble the detector read: the sine
// fitted to the draft's played line, at its read depth and its read anchor,
// UNCORRECTED. And because the played line is `detected + curve`, the drawn
// line jumps by exactly the same amount as the audio AT EVERY FRAME CENTRE —
// display equals render there. ⚠️ Between centres (C5a-F9, measured) the
// render cancels the detected line as the curve INTERPOLATES it while `G` is
// a smooth sine, so the audio carries ≈ 2 % of the width RMS more than the
// line shows, coherent with the sine: 0.2 c at ±10 c, ≈ 1 c on top of a grid
// round-up at ±40 c. Small, but the line does not predict it.
//
// Arithmetic at the one block where both corrections exist (146.8 Hz: response
// 0.83, lag +6.7 ms), on a 5.5 Hz ±40 c wobble:
//  * lag subtracted: peak jump `2A·sin(π·f·lag)` = 2·40·sin(π·5.5·0.0067) ≈ 9.2 c
//    (6.5 c RMS), the new sine 13° out of step with the line on screen;
//  * depth ÷ response: `A·(1/r − 1)` = 40·0.205 ≈ 8.2 c peak, and 10 c once the
//    seed is quantised to 5 (48.2 → 50);
//  * both: |40 − 50·e^{i·0.23}| ≈ 14.4 c peak, 10.2 c RMS.
// Each sits UNDER §15 T14's own 10 c RMS bound, which is why T14 alone could
// not have caught either; `PitchWobbleGestureTests` adds a tight leg that can.
//
// So the DEFAULT (`PitchWobbleHandoffSeed.asRead`) seeds the read depth and the
// read anchor, and needs no `response` — the §18.2 refusal falls with the
// calibration it existed for. `.calibrated` keeps the design as written (÷
// response, τ − lag, refused where response is nil) behind the one switch,
// tested, for C5a-L2 to arbitrate by ear. What does NOT change: §18.3 still
// prints no width where no block covers the pitch (that rule is about calling
// a READING a measurement of the singer, not about the seed), and at low pitch
// the detector's under-read leaves `(1 − r)` of the singer's wobble in the
// audio at its old rate after a speed change — the SAME residual the two-step
// route (smooth flat, then add) leaves, so refusing bought nothing audible.
//
// ⭐ C5a-F9 — THE SAME ARGUMENT UNDER THE 20 c REPORT FLOOR. The floor decides
// whether the app can honestly NAME a wobble; it is a display rule, not a
// continuity rule. A ±40 c wobble narrowed to keep 0.45 still plays ±18 c and
// reads `.noWobble`; seeding that as width 0 dropped all 18 c (≈ 12.7 c RMS)
// from the line and the audio at the crossing tick. So a `.noWobble` reading
// of a draft that is NOT flat by construction seeds from the floor-free fit
// at the sung rate (`subFloorFit`, `PitchWobbleEstimate.refit`); with no sung
// rate to fit at, it is refused like an unmeasurable reading, whose route is
// continuous. Only a draft flat BY CONSTRUCTION hands off with no wobble.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⚠️ THE KEEP → DRIFT COUPLING HAS TWO POLICIES AND ONE SWITCH
// ═══════════════════════════════════════════════════════════════════════════
//
// Natural tuning §3b amends §5.2: if G3 passes (a separator that does not
// invert), DECOUPLE — Wobble writes `vibratoScale` only; otherwise couple on
// the way down as `driftScale = d0 · k / k0`. §5.2's `min(d0, k)` is retired:
// with an independent Drift tool `d0 > k0` is reachable, and `min` then jumps
// with zero travel. G3 has not run and the v2 separator
// (`PitchCorrectionMath.triangularAverage`) does not exist, so the default is
// `.proportional`; G3's owner flips `PitchWobbleGesture.coupling`.

// MARK: - The one swappable mapping (§4.3, D3)

/// The three answers to the axis question on the user's page, as one enum.
/// `PitchWobbleGesture.layout` holds the user's answer; nothing else reads a
/// pointer's translation for this gesture.
public enum PitchWobbleHandleLayout: String, Sendable, Equatable, CaseIterable {
    /// One knob: ← → speed, ↑ ↓ width. THE USER'S ANSWER (`vibrato-axis: x-speed`).
    case sidewaysIsSpeed
    /// "The other way round": one knob, ← → width, ↑ ↓ speed.
    case sidewaysIsWidth
    /// A speed knob (← →) and a width knob (↑ ↓).
    case twoHandles
}

/// Which knob a press grabbed. One-knob layouts only ever grab `.both`.
public enum PitchWobbleKnob: String, Sendable, Equatable {
    case both, speed, width
}

/// Pointer travel in points, already mapped by the layout: `+speed` is
/// faster, `+width` is wider. Everything downstream is layout-agnostic.
public struct PitchWobbleTravel: Sendable, Equatable {
    public var speed: Double
    public var width: Double

    public init(speed: Double, width: Double) {
        self.speed = speed
        self.width = width
    }

    public static let zero = PitchWobbleTravel(speed: 0, width: 0)
}

/// Where one knob is drawn and grabbed.
public struct PitchWobbleKnobPlacement: Sendable, Equatable {
    public let knob: PitchWobbleKnob
    public let centre: CGPoint

    public init(knob: PitchWobbleKnob, centre: CGPoint) {
        self.knob = knob
        self.centre = centre
    }
}

// MARK: - The two switches that wait on evidence

/// How the keep lever moves `driftScale` (natural tuning §3b, amending §5.2).
public enum PitchWobbleDriftCoupling: String, Sendable, Equatable, CaseIterable {
    /// G3 failed or has not run: on the way DOWN, `driftScale = d0 · k / k0`
    /// (k0, d0 at mouse-down; `k0 = 0` leaves drift untouched); on the way up
    /// drift stays at d0. Continuous at `k = k0`, 0 at `k = 0` when `d0 > 0`,
    /// so pulling a note down still straightens its slides and flat is both
    /// scales at 0 (§5.3, D5).
    case proportional
    /// G3 passed (the v2 separator does not invert): the Wobble tool writes
    /// `vibratoScale` only, and the Drift tool owns `driftScale`.
    case decoupled
}

/// What the handoff seeds the new wobble from (§6.2 step 3, §18.2, §18.7).
/// See the banner for the arithmetic.
public enum PitchWobbleHandoffSeed: String, Sendable, Equatable, CaseIterable {
    /// THE DEFAULT: the draft's played reading as read — depth and anchor
    /// uncorrected — which is what the render subtracts, so the crossing tick
    /// is continuous on screen and in the audio. Needs no `response`, so it is
    /// never refused for the pitch.
    case asRead
    /// The design as written: depth `÷ PitchWobbleEstimate.response(pitchHz:)`,
    /// anchor `− anchorLagSeconds(pitchHz:)` where one is measured, and the
    /// handoff REFUSED where `response` is nil (§18.2). Kept for C5a-L2.
    case calibrated
}

// MARK: - What a press starts (§5.1, §5.5, §18.3)

/// The branch a gesture edits, decided ONCE at mouse-down (D4). A gesture never
/// changes branch by passing through flat; the one change inside a gesture is
/// the one-way handoff from `.own` to a new wobble (§6).
public enum PitchWobbleStart: Sendable, Equatable {
    /// Edit the singer's own wobble with the keep lever. `sung` is the reading
    /// of what was SUNG (`PitchWobbleEstimate.sung`); a note with no reading
    /// arrives as `.unmeasurable(.tooFewSamples)` — smoothing only.
    case own(sung: PitchWobbleReading)
    /// Edit (or start) a new wobble. `fromNothing`: the note has no generated
    /// wobble yet, so the draft parks a rate, a centre anchor and onset 0.
    case made(fromNothing: Bool)
    /// This note cannot be edited now; the sentence says why (drawn in
    /// `PanelRefusalLine`, never beside the knob).
    case refused(String)

    public var refusal: String? {
        if case .refused(let sentence) = self { return sentence }
        return nil
    }
}

/// Which door a press came through (unpitched-notes §4): the top-centre DOT,
/// or anywhere else on the note. The `debug.pitchEditor` echo's `door` key.
public enum PitchWobbleDoor: String, Sendable, Equatable {
    case dot
    case drag
}

/// What releasing a press in the Wobble tool does.
public enum PitchWobbleRelease: Sendable, Equatable {
    /// A click on the dot: one step bigger (plain) or smaller (⌥).
    case step(bigger: Bool)
    /// The press travelled: the gesture ends, `PitchWobbleSession.commit()`.
    case endDrag
    /// A click elsewhere on the note: the router's ordinary click (selection).
    case click
}

/// The handoff's outcome at the crossing tick (§6.2 steps 3–5).
public enum PitchWobbleHandoffResult: Sendable, Equatable {
    /// The new draft: both mechanisms in one edit (scales per the coupling,
    /// the generator seeded), and the heard rate it starts at.
    case seeded(NoteVibratoEdit, heardRateHz: Double)
    /// Speed stays inert; the sentence says the one route that works.
    case refused(String)
}

/// A sine fitted to a note's played samples at a KNOWN rate, with NO floor
/// (`PitchWobbleEstimate.refit`): what the handoff seeds from when the played
/// reading falls under the 20 c report floor (C5a-F9). Rate per second of the
/// played line's axis (edited seconds); anchor a rising zero crossing there.
public struct PitchWobbleFit: Sendable, Equatable {
    public let rateHz: Double
    public let depthCents: Double
    public let anchorSeconds: Double

    public init(rateHz: Double, depthCents: Double, anchorSeconds: Double) {
        self.rateHz = rateHz
        self.depthCents = depthCents
        self.anchorSeconds = anchorSeconds
    }
}

/// One line of drawn text. `isWarning` is the red state (§9.2: a heard rate
/// above what plays cleanly after a clip-speed change).
public struct PitchWobbleReadout: Sendable, Equatable {
    public let text: String
    public let isWarning: Bool

    public init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }
}

/// Another selected note riding a keep-lever gesture (natural tuning §3b).
public struct PitchWobbleMember: Sendable, Equatable {
    public let segment: NoteSegment
    /// Its own sung reading (`nil` = none), for its own widening cap.
    public let sung: PitchWobbleReading?

    public init(segment: NoteSegment, sung: PitchWobbleReading?) {
        self.segment = segment
        self.sung = sung
    }
}

/// What a gesture hands the store: absolute edits, one item per note that
/// changes, for `setClipNotesVibrato` (or `setClipNoteVibrato` for one).
public struct PitchWobbleCommit: Sendable, Equatable {
    /// Every item carries all six fields (design §10 "the UI's commit").
    public let items: [NoteVibratoItem]
    /// A selection gesture: the store's group undo key
    /// (`PitchCorrectionUndoKey.vibratoGroup`), not the per-note `.vibrato`.
    public let isGroup: Bool
    /// Which door the gesture came through.
    public let door: PitchWobbleDoor

    public init(items: [NoteVibratoItem], isGroup: Bool, door: PitchWobbleDoor) {
        self.items = items
        self.isGroup = isGroup
        self.door = door
    }
}

// MARK: - The gesture's constants and pure functions

/// THE Wobble tool's arithmetic. Every constant is a PICK unless it cites a
/// measurement; each is one line so a listening pick changes one number.
public enum PitchWobbleGesture {

    /// ⭐ THE ONE PLACE the user's answer to the axis question lives
    /// (`vibrato-axis: x-speed`, 2026-09-24). Any of the three answers is this
    /// one line; the help follows (T11).
    public static let layout: PitchWobbleHandleLayout = .sidewaysIsSpeed

    /// ⭐ THE ONE SWITCH for the keep → drift rule. `.proportional` until
    /// natural tuning's G3 passes and the v2 separator lands (banner).
    public static let coupling: PitchWobbleDriftCoupling = .proportional

    /// ⭐ THE ONE SWITCH for the handoff seed. `.asRead`: continuous by the
    /// render rule (banner); `.calibrated` is §18.2/§18.7 as written.
    public static let handoffSeed: PitchWobbleHandoffSeed = .asRead

    // MARK: The picks

    /// §6.2: speed does nothing on the singer's own wobble until the pointer
    /// has gone this far sideways AND at least as far as it has gone up or down.
    public static let deadZonePoints: Double = 16

    /// §5.2: the keep factor's step, and its ceiling ("twice as wide is already
    /// an exaggeration a novice will not mistake for subtle"). The model allows
    /// 0…4 (`NoteSegment.shapeScaleRange`); this is the UI's own pick.
    public static let keepStep: Double = 0.05
    public static let keepCeiling: Double = 2
    /// §18.3 Defect 2: without evidence of real movement, up stops at "as you
    /// sang it".
    public static let unprovenKeepCeiling: Double = 1

    /// §5.2's gain floor, cents: a small wobble must not give an uncontrollable
    /// gain. And the rows of travel per whole keep step when there is no depth.
    public static let keepGainFloorCents: Double = 20
    public static let unmeasuredKeepRowsPerUnit: Double = 3

    /// §5.4: a new wobble's width step, cents ("rounded to the nearest 5": the
    /// generator's honest bound is ±7 c).
    public static let depthStep: Double = 5

    /// §5.4: heard rate per point of speed travel, its step, and its floor.
    /// The ceiling is NOT a pick: `NoteVibratoLimits.storedRateCeiling`.
    public static let heardRatePerPoint: Double = 0.05
    public static let heardRateStep: Double = 0.1
    public static let heardRateFloor: Double = 2

    /// §5.4: where a new wobble's speed starts when nothing is parked — the
    /// reference's first readout and the middle of sung vibrato.
    public static let startingHeardRate: Double = 5.5

    /// The onset a wobble this tool CREATES gets: 0, full size at once — the
    /// user's `wobble-onset: same` answer ("keep the built default"). D14's
    /// `min(0.25, 0.3 × length)` is superseded. An existing onset is kept.
    public static let newWobbleOnsetSeconds: Double = 0

    /// §4.1: ⌥ held means fine control — every GAIN divided by this, read per
    /// tick. The dead zone is a distance, not a gain, and is not divided.
    public static let fineDivisor: Double = 4

    /// Unpitched-notes §4: a dot click is one step of keep, or of width.
    public static let dotKeepStep: Double = 0.10
    public static let dotDepthStep: Double = 5

    /// Unpitched-notes §4 / §4.3: the dot is 10 pt across and grabs within
    /// 12 pt; `twoHandles`' knobs grab within 12 pt and need a 40 pt blob.
    public static let dotDiameter: CGFloat = 10
    public static let knobHitRadius: CGFloat = 12
    public static let twoHandlesMinimumWidth: CGFloat = 40

    // MARK: The layout (§4.3)

    /// Pointer translation (SwiftUI's: `dy` grows DOWN) → travel, for the knob
    /// a press grabbed. ⭐ The only function that reads a translation.
    ///
    /// | layout | knob | speed | width |
    /// |---|---|---|---|
    /// | `sidewaysIsSpeed` | any | `+dx` | `−dy` |
    /// | `sidewaysIsWidth` | any | `−dy` | `+dx` |
    /// | `twoHandles` | `speed` | `+dx` | `0` |
    /// | `twoHandles` | `width` | `0` | `−dy` |
    /// | `twoHandles` | `both` | `+dx` | `−dy` (never grabbed: `knob(at:…)`) |
    public static func travel(translation: CGSize, knob: PitchWobbleKnob,
                              layout: PitchWobbleHandleLayout = layout) -> PitchWobbleTravel {
        let dx = Double(translation.width)
        let up = -Double(translation.height)
        switch layout {
        case .sidewaysIsSpeed:
            return PitchWobbleTravel(speed: dx, width: up)
        case .sidewaysIsWidth:
            return PitchWobbleTravel(speed: up, width: dx)
        case .twoHandles:
            switch knob {
            case .speed: return PitchWobbleTravel(speed: dx, width: 0)
            case .width: return PitchWobbleTravel(speed: 0, width: up)
            case .both: return PitchWobbleTravel(speed: dx, width: up)
            }
        }
    }

    /// Where the knobs sit on a note's blob. One-knob layouts: THE DOT, at the
    /// blob's top centre (unpitched-notes §4: it replaces §4.1's centre knob,
    /// so a note still has one handle). `twoHandles`: on the same top edge at
    /// 1/3 (speed) and 2/3 (width) of the width, or none on a blob narrower
    /// than `twoHandlesMinimumWidth`.
    public static func knobs(in blobRect: CGRect,
                             layout: PitchWobbleHandleLayout = layout) -> [PitchWobbleKnobPlacement] {
        let rect = blobRect.standardized
        switch layout {
        case .sidewaysIsSpeed, .sidewaysIsWidth:
            return [PitchWobbleKnobPlacement(knob: .both, centre: dot(in: rect))]
        case .twoHandles:
            guard rect.width >= twoHandlesMinimumWidth else { return [] }
            return [
                PitchWobbleKnobPlacement(knob: .speed,
                                         centre: CGPoint(x: rect.minX + rect.width / 3, y: rect.minY)),
                PitchWobbleKnobPlacement(knob: .width,
                                         centre: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.minY)),
            ]
        }
    }

    /// The knob a press on the blob grabs: `.both` in a one-knob layout (the
    /// whole blob is the grab area, §4.3); in `twoHandles` the nearer knob, or
    /// `nil` on a blob too narrow to hold two (the view says
    /// `PitchWobbleCopy.zoomInForTwoHandles` and ignores the press).
    public static func knob(at point: CGPoint, in blobRect: CGRect,
                            layout: PitchWobbleHandleLayout = layout) -> PitchWobbleKnob? {
        let placements = knobs(in: blobRect, layout: layout)
        guard let first = placements.first else { return nil }
        guard placements.count > 1 else { return first.knob }
        return placements.min {
            abs($0.centre.x - point.x) < abs($1.centre.x - point.x)
        }?.knob
    }

    /// THE DOT's centre: x at the note's temporal centre, y on the blob's top
    /// edge (unpitched-notes §4).
    public static func dot(in blobRect: CGRect) -> CGPoint {
        let rect = blobRect.standardized
        return CGPoint(x: rect.midX, y: rect.minY)
    }

    /// Which door a press on a note came through: within `knobHitRadius` of the
    /// dot is the dot; anywhere else on the note is the drag door.
    public static func door(at point: CGPoint, blobRect: CGRect) -> PitchWobbleDoor {
        let centre = dot(in: blobRect)
        return hypot(point.x - centre.x, point.y - centre.y) <= knobHitRadius ? .dot : .drag
    }

    /// Whether a press has become a drag. ⚠️ **THE ROUTER'S SLOP, ONE HOME**
    /// (`PitchEditorGestureRouter.hasTravelled`: 4 pt, radial, `>=`). The dot
    /// design's "release within 3 pt" is superseded: two thresholds on one
    /// press would let the router call a release a click while the dot called
    /// it a drag. The design's own plant ("4 pt of travel is a drag, not a
    /// step") holds under this.
    public static func travelled(from origin: CGPoint, to point: CGPoint) -> Bool {
        PitchEditorGestureRouter.hasTravelled(from: origin, to: point)
    }

    /// What a release does (unpitched-notes §4's input table).
    public static func release(door: PitchWobbleDoor, travelled: Bool,
                               optionHeld: Bool) -> PitchWobbleRelease {
        if travelled { return .endDrag }
        switch door {
        case .dot: return .step(bigger: !optionHeld)
        case .drag: return .click
        }
    }

    /// The drawn help (§4.3), derived from the layout so a swap cannot leave it
    /// lying. The ⌘ sentence only when the Shape tool exists (§3).
    public static func help(layout: PitchWobbleHandleLayout = layout,
                            drawToolAvailable: Bool) -> String {
        var sentences = [PitchWobbleCopy.helpDirections(layout),
                         PitchWobbleCopy.helpPianoKey]
        if drawToolAvailable { sentences.append(PitchWobbleCopy.helpHoldCommand) }
        sentences.append(PitchWobbleCopy.helpLetGo)
        return sentences.joined(separator: " ")
    }

    // MARK: The branch (§5.1, §5.5, §18.3)

    /// Which branch a press on `segment` edits, in the design's order:
    ///  0. a SOUND (`.unpitched`) is refused — no pitch, no wobble (§1.7; the
    ///     store refuses the same sentence);
    ///  1. the basis gate (§5.5): under `.estimate` only a note that already
    ///     plays a new wobble with BOTH scales at 1 is editable, because nothing
    ///     it writes or keeps needs the contour;
    ///  2. a note that plays a new wobble → `.made(fromNothing: false)`;
    ///  3. a sung reading of `.noWobble` → `.made(fromNothing: true)`: there is
    ///     nothing of the singer's the app can measure to widen, so up adds one;
    ///  4. otherwise → `.own`, including a note already pulled flat (flat is
    ///     the bottom of your wobble, not the start of a new one).
    ///
    /// `sung` is `PitchWobbleEstimate.sung(segment, contour:)`: `nil` reads as
    /// `.unmeasurable(.tooFewSamples)` (no analysis → smoothing only).
    public static func classify(segment: NoteSegment, sung: PitchWobbleReading?,
                                basis: PitchPlayedLine.Basis) -> PitchWobbleStart {
        if segment.origin == .unpitched { return .refused(NoteVibratoLimits.noPitchHereSentence) }
        if case .estimate(let reason) = basis {
            let needsNoContour = segment.hasGeneratedVibrato
                && segment.vibratoScale == 1 && segment.driftScale == 1
            guard needsNoContour else {
                return .refused(reason == PitchPlayedLine.pendingReason
                                ? PitchWobbleCopy.refusedWhileMatching
                                : PitchWobbleCopy.refusedNoAnalysis)
            }
            return .made(fromNothing: false)
        }
        if segment.hasGeneratedVibrato { return .made(fromNothing: false) }
        let reading = sung ?? .unmeasurable(.tooFewSamples)
        if case .noWobble = reading { return .made(fromNothing: true) }
        return .own(sung: reading)
    }

    /// How far UP the keep lever may go on the singer's own wobble (§18.3
    /// Defect 2): `keepCeiling` with evidence of real movement, else
    /// `unprovenKeepCeiling` (1, "as you sang it").
    ///
    /// ⭐ **Evidence needs no private API.** Defect 2 allows widening on a
    /// `.wobble`, or on an unmeasurable note "whose estimator ran and fitted a
    /// depth ≥ `reportFloorCents`". The estimator checks the report floor
    /// FIRST (`PitchWobbleEstimate.Analysis.step`: floor, then scan edge,
    /// `tooShort`, fit), so every `.tooShort` and `.tooUneven` it returns
    /// already fitted at least 20 c. `.tooFewSamples` never ran a fit (fewer
    /// than 24 frames). `PitchWobbleGestureTests` pins that order from here, so
    /// a reorder in DAWCore turns this red instead of silently widening
    /// artefacts. (The two degenerate paths — no solvable fit, fewer than three
    /// distinct instants — are unreachable with real frames.)
    public static func keepCap(sung: PitchWobbleReading) -> Double {
        switch sung {
        case .wobble, .unmeasurable(.tooShort), .unmeasurable(.tooUneven):
            return keepCeiling
        case .unmeasurable(.tooFewSamples), .noWobble:
            return unprovenKeepCeiling
        }
    }

    /// §5.2: keep per point of width travel, so the top of the wobble follows
    /// the pointer — `1 / (rowHeight × max(D, 20) / 100)` with `D` the sung
    /// depth, or `1 / (3 × rowHeight)` with no depth. `rowHeight` is points
    /// per semitone (100 cents).
    public static func keepPerPoint(sung: PitchWobbleReading, rowHeight: Double) -> Double {
        let row = sanitisedRowHeight(rowHeight)
        if case .wobble(_, let depth, _, _) = sung {
            return 1 / (row * max(depth, keepGainFloorCents) / 100)
        }
        return 1 / (unmeasuredKeepRowsPerUnit * row)
    }

    /// §5.4: cents of new-wobble width per point, so its top follows the pointer.
    public static func depthPerPoint(rowHeight: Double) -> Double {
        100 / sanitisedRowHeight(rowHeight)
    }

    // MARK: The coupling (natural tuning §3b)

    /// `driftScale` for keep `k`, from `k0`/`d0` at mouse-down. See
    /// `PitchWobbleDriftCoupling`. Never jumps: at `k = k0` it is `d0` under
    /// both policies.
    public static func driftScale(keep k: Double, keepAtStart k0: Double,
                                  driftAtStart d0: Double,
                                  coupling: PitchWobbleDriftCoupling = coupling) -> Double {
        switch coupling {
        case .decoupled:
            return d0
        case .proportional:
            return k < k0 && k0 > 0 ? d0 * k / k0 : d0
        }
    }

    /// §18.3 Defect 1: a draft whose wobble is removed BY CONSTRUCTION needs no
    /// measurement to hand off continuously — its played line is the target
    /// line, so the handoff reads it as `.noWobble` whatever its sample count.
    /// Proportional: both scales 0 (D5). Decoupled: `vibratoScale` 0 (the v2
    /// separator does not invert, and drift is the Drift tool's).
    public static func isFlatByConstruction(_ segment: NoteSegment,
                                            coupling: PitchWobbleDriftCoupling = coupling) -> Bool {
        switch coupling {
        case .proportional: return segment.vibratoScale == 0 && segment.driftScale == 0
        case .decoupled: return segment.vibratoScale == 0
        }
    }

    /// Natural tuning §3b: double-click in the Wobble tool toggles the note
    /// between as sung and flat (Melodyne semantics: the value it leaves is not
    /// remembered; undo restores it). `nil` for a sound. Proportional: both
    /// scales together, so "flat" is D5's flat and "as sung" is keep 1, drift 1;
    /// decoupled: `vibratoScale` only. One step, `structuralKey` (the caller's).
    public static func doubleClickEdit(_ segment: NoteSegment,
                                       coupling: PitchWobbleDriftCoupling = coupling) -> NoteVibratoEdit? {
        guard segment.origin != .unpitched else { return nil }
        let toFlat = segment.vibratoScale != 0
        let target: Double = toFlat ? 0 : 1
        switch coupling {
        case .proportional: return NoteVibratoEdit(vibratoScale: target, driftScale: target)
        case .decoupled: return NoteVibratoEdit(vibratoScale: target)
        }
    }

    // MARK: Heard rate (design V5: heard = stored ÷ stretchRatio)

    /// The fastest HEARD rate this control reaches on a clip, on the 0.1 grid
    /// and never above what the store keeps: `storedRateCeiling ÷ ratio`,
    /// rounded DOWN. 8.0 at ratio ≤ 1; 6.4 at 1.25 (a slowed clip).
    public static func heardRateCeiling(stretchRatio: Double) -> Double {
        let ratio = sanitisedRatio(stretchRatio)
        let heard = NoteVibratoLimits.storedRateCeiling(stretchRatio: ratio) / ratio
        return (heard / heardRateStep + 1e-9).rounded(.down) / (1 / heardRateStep)
    }

    /// Where a new wobble's speed starts, heard: a parked stored rate if the
    /// note carries one (inert at depth 0, V2), else `startingHeardRate`,
    /// within this clip's ceiling.
    static func startingHeard(parkedRate: Double, ratio: Double) -> Double {
        parkedRate > 0 ? parkedRate / ratio
            : min(startingHeardRate, heardRateCeiling(stretchRatio: ratio))
    }

    // MARK: The handoff (§6.2 steps 3–5, §18.2, §18.3 Defect 1)

    /// The new draft at the crossing tick, or the refusal.
    ///
    /// - `draft`: the draft as it stands at that tick (keep and drift already
    ///   moved), as stored-model values.
    /// - `reading`: `PitchWobbleEstimate.played(draft, line:)` over the DRAFT
    ///   played line with any drawn (C5b) shape cleared from its table copy
    ///   (§6.2 step 1, §13) — edited seconds, so the anchor is mapped back
    ///   through `timeWarp` (§11.3). A flat-by-construction draft reads as
    ///   `.noWobble` here whatever is passed (Defect 1).
    /// - `sung`: the mouse-down reading, for a flat handoff's speed.
    /// - `subFloorFit`: `subFloorFit(of:line:sung:)` over the same
    ///   draft line — used only when `reading` is `.noWobble` and the draft is
    ///   NOT flat by construction (C5a-F9, below).
    ///
    /// `.wobble` → both mechanisms in one edit: scales per the coupling, the
    /// heard rate `quantise(f ÷ ratio, 0.1)`, the width and the rising-crossing
    /// anchor per `seed` (the banner), onset `newWobbleOnsetSeconds`.
    /// Flat by construction → scales per the coupling, width 0, the sung speed
    /// (or 5.5), the note's centre as anchor: flat on both sides, so continuous.
    /// `.unmeasurable` → refused with §18.3's one route that works.
    ///
    /// ⭐ **C5a-F9: `.noWobble` IS NOT FLAT.** The 20 c report floor answers
    /// "can the app honestly NAME this wobble?" — a display and classification
    /// rule. It is not a continuity rule: a ±40 c wobble narrowed to keep 0.45
    /// still plays ±18 c, reads `.noWobble`, and a flat seed would drop those
    /// 18 c from the line and the audio at the crossing tick. The banner's
    /// argument holds under the floor too — the only continuous seed is the
    /// sine fitted to the played line — so a `.noWobble` reading of a draft
    /// that is NOT flat by construction seeds from `subFloorFit`, the
    /// floor-free fit at the sung rate, exactly as a `.wobble` reading seeds
    /// from itself. With no such fit (the sung reading had no trustworthy rate:
    /// §18.1.3's "too uncertain to seed a handoff") it is refused like an
    /// unmeasurable one, whose route — smooth it flat first — is continuous.
    /// Only a draft flat BY CONSTRUCTION hands off with no wobble.
    public static func handoff(draft: NoteSegment, reading: PitchWobbleReading,
                               sung: PitchWobbleReading, subFloorFit: PitchWobbleFit? = nil,
                               stretchRatio: Double,
                               timeWarp: PitchTimeWarp? = nil,
                               coupling: PitchWobbleDriftCoupling = coupling,
                               seed: PitchWobbleHandoffSeed = handoffSeed) -> PitchWobbleHandoffResult {
        let ratio = sanitisedRatio(stretchRatio)
        let ceiling = heardRateCeiling(stretchRatio: ratio)
        var effective = reading
        if isFlatByConstruction(draft, coupling: coupling) {
            effective = .noWobble
        } else if effective == .noWobble {
            guard let fit = subFloorFit else { return .refused(PitchWobbleCopy.handoffRefused) }
            effective = .wobble(rateHz: fit.rateHz, depthCents: fit.depthCents,
                                anchorSeconds: fit.anchorSeconds, fit: 0)
        }
        let drift: Double? = coupling == .proportional ? 0 : nil
        func seeded(heard: Double, depth: Double, anchor: Double) -> PitchWobbleHandoffResult {
            let edit = NoteVibratoEdit(vibratoRateHz: heard * ratio, vibratoDepthCents: depth,
                                       vibratoOnsetSeconds: newWobbleOnsetSeconds,
                                       vibratoPhaseAnchorSeconds: anchor,
                                       vibratoScale: 0, driftScale: drift)
            return .seeded(edit, heardRateHz: heard)
        }
        switch effective {
        case .wobble(let rateHz, let depthCents, let anchorSeconds, _):
            var depth = depthCents
            var anchorEdited = anchorSeconds
            if seed == .calibrated {
                guard let response = PitchWobbleEstimate.response(pitchHz: draft.detectedHz) else {
                    return .refused(PitchWobbleCopy.handoffRefused)
                }
                depth /= response
                anchorEdited -= PitchWobbleEstimate.anchorLagSeconds(pitchHz: draft.detectedHz) ?? 0
            }
            let heard = clampHeard(quantiseHeard(rateHz / ratio), ceiling: ceiling)
            let anchor = timeWarp?.sourceSecond(forEditedSecond: anchorEdited) ?? anchorEdited
            return seeded(heard: heard, depth: clampDepth(quantiseDepth(depth)), anchor: anchor)
        case .noWobble:
            var heard = min(startingHeardRate, ceiling)
            if case .wobble(let sungRate, _, _, _) = sung {
                heard = clampHeard(quantiseHeard(sungRate / ratio), ceiling: ceiling)
            }
            return seeded(heard: heard, depth: 0, anchor: centreSeconds(draft))
        case .unmeasurable:
            return .refused(PitchWobbleCopy.handoffRefused)
        }
    }

    /// The played line's wobble at the SUNG rate with no floor (C5a-F9):
    /// `PitchWobbleEstimate.refit` — the design's own per-tick readout fit
    /// (§8.2 step 7), which applies no floor — over `draft`'s played samples
    /// (`PitchWobbleEstimate.playedSamples`, the one home of `played`'s
    /// attribution, so this fit and the reading cannot select differently).
    ///
    /// The sung rate is per SOURCE second; the samples are timed on the
    /// line's own axis (`Point.editedSeconds`). The rate is converted by the
    /// line's OWN edited-per-source slope across the note — measured on the
    /// points, not assumed from a `PitchTimeWarp` — so the fit and the times it
    /// fits cannot disagree, whether or not the line carries a retime (W is
    /// linear inside a note: its knots are note edges). `nil` without a sung
    /// `.wobble` (no rate worth seeding) or when the fit is degenerate.
    public static func subFloorFit(of draft: NoteSegment, line: PitchPlayedLine,
                                   sung: PitchWobbleReading) -> PitchWobbleFit? {
        guard case .wobble(let sungRate, _, _, _) = sung else { return nil }
        let samples = PitchWobbleEstimate.playedSamples(draft, line: line)
        var rate = sungRate
        if let firstSource = samples.sourceSeconds.first, let lastSource = samples.sourceSeconds.last,
           let firstEdited = samples.times.first, let lastEdited = samples.times.last,
           lastSource > firstSource {
            let slope = (lastEdited - firstEdited) / (lastSource - firstSource)
            if slope > 0 && slope.isFinite { rate = sungRate / slope }
        }
        guard let fit = PitchWobbleEstimate.refit(times: samples.times, cents: samples.cents,
                                                  rateHz: rate) else { return nil }
        return PitchWobbleFit(rateHz: rate, depthCents: fit.depthCents,
                              anchorSeconds: fit.anchorSeconds)
    }

    // MARK: Quantisation and ranges (§9.4: the UI quantises, so what is shown is what is stored)

    /// Keep, on the 0.05 grid. `(x × 20).rounded() / 20` lands on the nearest
    /// double to n/20, so 0.3 reads back as 0.3.
    static func quantiseKeep(_ k: Double) -> Double {
        (k / keepStep).rounded() / (1 / keepStep)
    }

    /// Heard rate, on the 0.1 grid.
    static func quantiseHeard(_ h: Double) -> Double {
        (h / heardRateStep).rounded() / (1 / heardRateStep)
    }

    /// Width, on the 5 c grid (exact for whole multiples).
    static func quantiseDepth(_ d: Double) -> Double {
        (d / depthStep).rounded() * depthStep
    }

    static func clampHeard(_ h: Double, ceiling: Double) -> Double {
        min(max(h, heardRateFloor), max(ceiling, heardRateFloor))
    }

    static func clampDepth(_ d: Double) -> Double {
        d.clamped(to: NoteSegment.vibratoDepthCentsRange)
    }

    /// The note's temporal centre, source seconds: where a created wobble's
    /// phase is anchored, so a speed change stretches the cycles around the
    /// knob (§7.3).
    static func centreSeconds(_ segment: NoteSegment) -> Double {
        (segment.startSeconds + segment.endSeconds) / 2
    }

    /// The ratio a `Clip` could hold (`Clip.stretchRatioRange`); non-finite or
    /// non-positive reads as 1 — the `NoteVibratoLimits.clamp` rule.
    static func sanitisedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        return ratio.clamped(to: Clip.stretchRatioRange)
    }

    /// A row height the gains can divide by; anything else reads as the
    /// editor's default (a zero row would make every gain infinite).
    static func sanitisedRowHeight(_ rowHeight: Double) -> Double {
        rowHeight.isFinite && rowHeight > 0 ? rowHeight : Double(PitchEditorGeometry.defaultRowHeight)
    }
}

// MARK: - One gesture, press to commit

/// One Wobble-tool gesture (or one dot click) from mouse-down to release.
///
/// A value: the view keeps one per press, feeds it every tick with
/// `update(travel:fine:playedLine:)`, rebuilds its draft line when that returns
/// `true` (§9.3: only when the QUANTISED draft changed), draws
/// `readout(played:)`, and on release hands `commit()` to the store. Nothing
/// here writes anything: a tick has no commit output at all, so "a drag tick
/// never commits" holds by the type (T10).
///
/// ⭐ **EVERY DRAFT GOES THROUGH `NoteVibratoLimits.clamp`** — the store's own
/// clamp — and onto the note only through `NoteVibratoClamp.applied(to:)`, so
/// what a drag draws is what its release stores (C5a-2's one-home rule). The
/// UI's own picks (keep ≤ 2, heard ≥ 2, the 0.05 / 0.1 / 5 grids) come first;
/// the model's ranges are the clamp's.
///
/// ⭐ **ZERO TRAVEL KEEPS THE STORED VALUE BIT FOR BIT.** A value is quantised
/// only once its axis has moved, and the upper keep limit is never below where
/// the note started, so a press that goes nowhere — or a note an agent stored
/// off the grid or above 2 — never jumps on the first tick (T2's identity).
public struct PitchWobbleSession: Sendable, Equatable {

    /// What the gesture is editing now.
    public enum Phase: String, Sendable, Equatable {
        /// The singer's own wobble, by the keep lever. Speed is inside the dead
        /// zone, or its handoff was refused.
        case own
        /// A new wobble, from mouse-down.
        case made
        /// A new wobble since the crossing tick (§6.2): one-way for the rest of
        /// the gesture; undo brings the singer's back in one step.
        case handedOff
        /// A selection (natural tuning §3b): the keep lever on every selected
        /// note, each from its own mouse-down value; speed does nothing.
        case group
    }

    /// The pressed note as stored at mouse-down.
    public let stored: NoteSegment
    /// The branch `PitchWobbleGesture.classify` chose (never `.refused`).
    public let start: PitchWobbleStart
    public let door: PitchWobbleDoor
    /// The clip's `stretchRatio`, sanitised (heard = stored ÷ this).
    public let stretchRatio: Double
    /// Points per semitone at mouse-down (`PitchEditorGeometry.rowHeight`).
    public let rowHeight: Double
    /// The clip's per-note time warp, for the handoff's anchor (§11.3).
    public let timeWarp: PitchTimeWarp?
    public let coupling: PitchWobbleDriftCoupling
    public let seed: PitchWobbleHandoffSeed
    /// The OTHER selected notes riding a group gesture, sounds dropped.
    public let members: [PitchWobbleMember]

    public private(set) var phase: Phase
    /// The pressed note as the gesture would store it now.
    public private(set) var draft: NoteSegment
    /// `members`' drafts, in `members` order.
    public private(set) var memberDrafts: [NoteSegment]
    /// The new wobble's heard rate (`.made` / `.handedOff`), per second.
    public private(set) var heardRateHz: Double
    /// Set when a handoff was refused in this gesture; speed stays inert. It
    /// is tried again only once the draft is flat by construction (Defect 1:
    /// the refusal's own route, "first drag down…, then sideways", works
    /// inside one gesture too).
    public private(set) var handoffRefusal: String?
    /// The last tick asked the keep lever above an unproven note's ceiling
    /// (§18.3 Defect 2).
    public private(set) var wideningBlocked = false
    /// The last tick's travel met the crossing condition: `|speed| ≥ 16 pt`
    /// and `|speed| ≥ |width|`.
    public private(set) var crossingHeld = false
    /// The gesture has moved a new wobble's speed.
    public private(set) var speedMoved = false

    /// The sung reading at mouse-down, `nil` off the own branch.
    let sung: PitchWobbleReading?
    let keepAtStart: Double
    let driftAtStart: Double
    /// `max(keepCap, keepAtStart)`: up never snaps a note back down.
    let keepLimit: Double
    /// The pressed note's keep ceiling is §18.3's "as you sang it" one.
    let keepIsUnproven: Bool
    let keepGain: Double
    private let memberStarts: [MemberStart]
    private var raw = PitchWobbleTravel.zero
    private var effective = PitchWobbleTravel.zero
    private var base: MadeBase?

    /// Where a new wobble's two axes start from.
    struct MadeBase: Sendable, Equatable {
        /// The draft the axes move: the stored note (`made`), with a parked
        /// rate, a centre anchor and onset 0 (`fromNothing`), or the seeded
        /// handoff draft (`handedOff`).
        let draft: NoteSegment
        let heard: Double
        /// The effective travel when this base was set (0 from mouse-down; the
        /// crossing tick's after a handoff, so nothing jumps there).
        let at: PitchWobbleTravel
    }

    struct MemberStart: Sendable, Equatable {
        let keep: Double
        let drift: Double
        let limit: Double
    }

    /// Start a gesture on `segment`, or `nil` for a refused start.
    ///
    /// - `start`: `PitchWobbleGesture.classify(segment:sung:basis:)`.
    /// - `members`: the other selected notes when the pressed one is in a
    ///   selection. A group runs only from a press on the OWN branch (its keep
    ///   lever needs the render's contour, which `.own` implies); a press on a
    ///   note playing a new wobble edits that note alone. Sounds are dropped
    ///   (the store would skip them).
    public static func begin(segment: NoteSegment, start: PitchWobbleStart,
                             stretchRatio: Double, rowHeight: Double,
                             timeWarp: PitchTimeWarp? = nil,
                             members: [PitchWobbleMember] = [],
                             door: PitchWobbleDoor = .drag,
                             coupling: PitchWobbleDriftCoupling = PitchWobbleGesture.coupling,
                             seed: PitchWobbleHandoffSeed = PitchWobbleGesture.handoffSeed)
    -> PitchWobbleSession? {
        guard start.refusal == nil else { return nil }
        return PitchWobbleSession(segment: segment, start: start, stretchRatio: stretchRatio,
                                  rowHeight: rowHeight, timeWarp: timeWarp, members: members,
                                  door: door, coupling: coupling, seed: seed)
    }

    private init(segment: NoteSegment, start: PitchWobbleStart, stretchRatio: Double,
                 rowHeight: Double, timeWarp: PitchTimeWarp?, members: [PitchWobbleMember],
                 door: PitchWobbleDoor, coupling: PitchWobbleDriftCoupling,
                 seed: PitchWobbleHandoffSeed) {
        typealias G = PitchWobbleGesture
        let ratio = G.sanitisedRatio(stretchRatio)
        let row = G.sanitisedRowHeight(rowHeight)
        self.stored = segment
        self.start = start
        self.door = door
        self.stretchRatio = ratio
        self.rowHeight = row
        self.timeWarp = timeWarp
        self.coupling = coupling
        self.seed = seed
        self.keepAtStart = segment.vibratoScale
        self.driftAtStart = segment.driftScale

        let sung: PitchWobbleReading?
        if case .own(let reading) = start { sung = reading } else { sung = nil }
        self.sung = sung
        let cap = sung.map(G.keepCap(sung:)) ?? G.keepCeiling
        self.keepLimit = max(cap, segment.vibratoScale)
        self.keepIsUnproven = cap == G.unprovenKeepCeiling && segment.vibratoScale <= cap
        self.keepGain = G.keepPerPoint(sung: sung ?? .unmeasurable(.tooFewSamples), rowHeight: row)

        let riders = sung == nil ? [] : members.filter {
            $0.segment.origin != .unpitched && $0.segment.id != segment.id
        }
        self.members = riders
        self.memberDrafts = riders.map(\.segment)
        self.memberStarts = riders.map {
            let memberCap = G.keepCap(sung: $0.sung ?? .unmeasurable(.tooFewSamples))
            return MemberStart(keep: $0.segment.vibratoScale, drift: $0.segment.driftScale,
                               limit: max(memberCap, $0.segment.vibratoScale))
        }

        switch start {
        case .made(let fromNothing):
            self.phase = .made
            var parked = segment
            var heard = segment.vibratoRateHz / ratio
            if fromNothing {
                heard = G.startingHeard(parkedRate: segment.vibratoRateHz, ratio: ratio)
                let edit = NoteVibratoEdit(
                    vibratoRateHz: segment.vibratoRateHz > 0 ? segment.vibratoRateHz : heard * ratio,
                    vibratoOnsetSeconds: G.newWobbleOnsetSeconds,
                    vibratoPhaseAnchorSeconds: G.centreSeconds(segment))
                parked = Self.write(edit, onto: segment, ratio: ratio) ?? segment
            }
            self.draft = parked
            self.heardRateHz = heard
            self.base = MadeBase(draft: parked, heard: heard, at: .zero)
        case .own, .refused:
            self.phase = riders.isEmpty ? .own : .group
            self.draft = segment
            self.heardRateHz = segment.vibratoRateHz / ratio
            self.base = nil
        }
    }

    // MARK: Ticks

    /// One pointer tick. `travel` is the gesture's TOTAL travel since
    /// mouse-down, from `PitchWobbleGesture.travel`; `fine` is ⌥ as held THIS
    /// tick (§4.1). Returns whether any draft changed.
    ///
    /// ⌥ divides the gains of the travel made while it is held (increments are
    /// accumulated), so pressing or releasing ⌥ mid-drag never jumps the value.
    /// The dead zone reads the raw travel: it is a distance, not a gain.
    ///
    /// `playedLine` is called AT MOST ONCE per gesture, at the crossing tick:
    /// the caller returns the played line built from its table with the given
    /// draft substituted (any drawn C5b shape cleared) — `PitchPlayedLine.make`,
    /// the line it draws. The session reads it (`PitchWobbleEstimate.played`,
    /// and under the floor `subFloorFit`). It is never called for a draft that
    /// is flat by construction (Defect 1), nor per tick (§8.2 step 7).
    @discardableResult
    public mutating func update(travel: PitchWobbleTravel, fine: Bool,
                                playedLine: (NoteSegment) -> PitchPlayedLine) -> Bool {
        guard travel.speed.isFinite, travel.width.isFinite else { return false }
        let gain = fine ? 1 / PitchWobbleGesture.fineDivisor : 1
        effective.speed += (travel.speed - raw.speed) * gain
        effective.width += (travel.width - raw.width) * gain
        raw = travel
        crossingHeld = abs(raw.speed) >= PitchWobbleGesture.deadZonePoints
            && abs(raw.speed) >= abs(raw.width)
        let before = (draft, memberDrafts)
        switch phase {
        case .own: tickOwn(playedLine: playedLine)
        case .group: tickGroup()
        case .made, .handedOff: tickMade()
        }
        return before.0 != draft || before.1 != memberDrafts
    }

    /// One dot click: one step bigger or smaller (unpitched-notes §4). Your
    /// wobble: keep ± 0.10 inside `[0, keepLimit]`, drift per the coupling. A
    /// new wobble: width ± 5 c inside the model's range (a note with none
    /// starts one at the parked speed). Returns whether the draft changed.
    @discardableResult
    public mutating func step(bigger: Bool) -> Bool {
        typealias G = PitchWobbleGesture
        let before = draft
        switch phase {
        case .own, .group:
            let requested = draft.vibratoScale + (bigger ? G.dotKeepStep : -G.dotKeepStep)
            wideningBlocked = bigger && keepIsUnproven && requested > keepLimit
            let keep = G.quantiseKeep(requested).clamped(to: 0...keepLimit)
            setKeep(keep)
        case .made, .handedOff:
            let depth = G.clampDepth(G.quantiseDepth(
                draft.vibratoDepthCents + (bigger ? G.dotDepthStep : -G.dotDepthStep)))
            if let next = Self.write(NoteVibratoEdit(vibratoDepthCents: depth), onto: draft,
                                     ratio: stretchRatio) {
                draft = next
            }
        }
        return before != draft
    }

    private mutating func tickOwn(playedLine: (NoteSegment) -> PitchPlayedLine) {
        typealias G = PitchWobbleGesture
        let requested = keepAtStart + effective.width * keepGain
        wideningBlocked = keepIsUnproven && effective.width > 0 && requested > keepLimit
        setKeep(keepValue(requested, from: keepAtStart, limit: keepLimit))
        guard crossingHeld, let sung else { return }
        let flat = G.isFlatByConstruction(draft, coupling: coupling)
        guard handoffRefusal == nil || flat else { return }
        var reading = PitchWobbleReading.noWobble
        var subFloor: PitchWobbleFit?
        if !flat {
            let line = playedLine(draft)
            reading = PitchWobbleEstimate.played(draft, line: line)
            if reading == .noWobble {
                subFloor = G.subFloorFit(of: draft, line: line, sung: sung)
            }
        }
        switch G.handoff(draft: draft, reading: reading, sung: sung, subFloorFit: subFloor,
                         stretchRatio: stretchRatio, timeWarp: timeWarp, coupling: coupling,
                         seed: seed) {
        case .seeded(let edit, let heard):
            guard let seeded = Self.write(edit, onto: draft, ratio: stretchRatio) else { return }
            draft = seeded
            phase = .handedOff
            heardRateHz = heard
            handoffRefusal = nil
            wideningBlocked = false
            base = MadeBase(draft: seeded, heard: heard, at: effective)
        case .refused(let sentence):
            handoffRefusal = sentence
        }
    }

    private mutating func tickGroup() {
        let delta = effective.width * keepGain
        wideningBlocked = keepIsUnproven && effective.width > 0 && keepAtStart + delta > keepLimit
        setKeep(keepValue(keepAtStart + delta, from: keepAtStart, limit: keepLimit))
        for index in memberDrafts.indices {
            let start = memberStarts[index]
            let keep = keepValue(start.keep + delta, from: start.keep, limit: start.limit)
            let drift = PitchWobbleGesture.driftScale(keep: keep, keepAtStart: start.keep,
                                                      driftAtStart: start.drift, coupling: coupling)
            if let next = Self.write(NoteVibratoEdit(vibratoScale: keep, driftScale: drift),
                                     onto: members[index].segment, ratio: stretchRatio) {
                memberDrafts[index] = next
            }
        }
    }

    private mutating func tickMade() {
        typealias G = PitchWobbleGesture
        guard let base else { return }
        let widthMoved = effective.width - base.at.width
        let speedTravel = effective.speed - base.at.speed
        let depth = widthMoved == 0 ? base.draft.vibratoDepthCents
            : G.clampDepth(G.quantiseDepth(base.draft.vibratoDepthCents
                                             + widthMoved * G.depthPerPoint(rowHeight: rowHeight)))
        var rate = base.draft.vibratoRateHz
        var heard = base.heard
        if speedTravel != 0 {
            heard = G.clampHeard(G.quantiseHeard(base.heard + speedTravel * G.heardRatePerPoint),
                                 ceiling: G.heardRateCeiling(stretchRatio: stretchRatio))
            rate = heard * stretchRatio
            speedMoved = true
        }
        let edit = NoteVibratoEdit(vibratoRateHz: rate, vibratoDepthCents: depth)
        guard let next = Self.write(edit, onto: base.draft, ratio: stretchRatio) else { return }
        draft = next
        heardRateHz = heard
    }

    /// The keep for a requested value: the start, bit for bit, while the width
    /// axis has not moved; else on the 0.05 grid inside `[0, limit]`.
    private func keepValue(_ requested: Double, from start: Double, limit: Double) -> Double {
        effective.width == 0 ? start
            : PitchWobbleGesture.quantiseKeep(requested).clamped(to: 0...limit)
    }

    private mutating func setKeep(_ keep: Double) {
        let drift = PitchWobbleGesture.driftScale(keep: keep, keepAtStart: keepAtStart,
                                                  driftAtStart: driftAtStart, coupling: coupling)
        let edit = coupling == .decoupled
            ? NoteVibratoEdit(vibratoScale: keep)
            : NoteVibratoEdit(vibratoScale: keep, driftScale: drift)
        if let next = Self.write(edit, onto: stored, ratio: stretchRatio) { draft = next }
    }

    /// `edit` through THE clamp, onto `segment`; `nil` when the clamp refuses
    /// (a non-finite value — the caller keeps its previous draft).
    static func write(_ edit: NoteVibratoEdit, onto segment: NoteSegment,
                      ratio: Double) -> NoteSegment? {
        (try? NoteVibratoLimits.clamp(edit, stretchRatio: ratio))?.applied(to: segment)
    }

    // MARK: The commit (§5.4's no-op rule, T10)

    /// What the release stores, or `nil` when the gesture plays exactly like
    /// the stored notes.
    ///
    /// ⛔ **A GESTURE WHOSE RESULT PLAYS LIKE THE STORED NOTE COMMITS NOTHING**
    /// (§5.4). A `fromNothing` draft parks a rate, a centre anchor and an onset;
    /// if it ends at width 0 those fields differ from the stored ones while the
    /// sound does not, and a commit would make `isEdited` true — a note drawn
    /// as edited that plays as sung. So a note is committed only when some
    /// field changed AND the draft or the stored note has a generated wobble,
    /// or a scale changed. Field inequality alone is not enough (T10's plant).
    public func commit() -> PitchWobbleCommit? {
        var items: [NoteVibratoItem] = []
        if let item = Self.item(draft: draft, stored: stored) { items.append(item) }
        for (draft, member) in zip(memberDrafts, members) {
            if let item = Self.item(draft: draft, stored: member.segment) { items.append(item) }
        }
        guard !items.isEmpty else { return nil }
        return PitchWobbleCommit(items: items, isGroup: phase == .group, door: door)
    }

    static func item(draft: NoteSegment, stored: NoteSegment) -> NoteVibratoItem? {
        let edit = NoteVibratoEdit(storedIn: draft)
        guard edit != NoteVibratoEdit(storedIn: stored) else { return nil }
        let plays = draft.hasGeneratedVibrato || stored.hasGeneratedVibrato
            || draft.vibratoScale != stored.vibratoScale || draft.driftScale != stored.driftScale
        return plays ? NoteVibratoItem(segmentId: stored.id, edit: edit) : nil
    }

    // MARK: The readout (§9, §18.3)

    /// The line drawn beside the knob and mirrored in the palette (§9.1).
    ///
    /// - `played`: the estimator over the CURRENT draft's played line (hover:
    ///   the stored note's), `PitchWobbleEstimate.played` — or, per tick, a
    ///   `refit` at the known rate compared against `reportFloorCents` (§8.2
    ///   step 7). Only the own branch reads it: a new wobble prints the ASKED
    ///   values (§9.3), never a fit.
    /// - `hasDrawnShape`: the note also carries a C5b drawn shape.
    ///
    /// ⛔ What it never prints (§9.3, T16): a width as `keep × depth`; a stored
    /// rate as heard; a cents number for `.noWobble` or `.unmeasurable`; a keep
    /// percentage (that is the DOT's tip, `dotTip()`); "0 cents" or "no wobble"
    /// for flat; a width for a note whose pitch no measured block covers
    /// (`PitchWobbleEstimate.response` is nil, §18.1.6).
    public func readout(played: PitchWobbleReading?, hasDrawnShape: Bool = false) -> PitchWobbleReadout {
        let drawn = hasDrawnShape ? PitchWobbleCopy.drawnChangesStayOnTop : ""
        switch phase {
        case .group:
            if crossingHeld { return PitchWobbleReadout(PitchWobbleCopy.speedOneNoteAtATime) }
            if wideningBlocked { return PitchWobbleReadout(PitchWobbleCopy.cannotWiden) }
            return PitchWobbleReadout(ownWords(played: played) + drawn)
        case .own:
            if crossingHeld, let refusal = handoffRefusal { return PitchWobbleReadout(refusal) }
            if wideningBlocked { return PitchWobbleReadout(PitchWobbleCopy.cannotWiden) }
            return PitchWobbleReadout(ownWords(played: played) + drawn)
        case .made, .handedOff:
            let words = madeWords()
            return words.isWarning ? words : PitchWobbleReadout(words.text + drawn)
        }
    }

    /// THE DOT's tip (unpitched-notes §4), drawn on hover and after each
    /// click. It states the SETTING — the keep as a share of how it was sung,
    /// in the user's words — never a cents depth for the singer's wobble. A
    /// new wobble's tip is the readout's own line.
    public func dotTip() -> PitchWobbleReadout {
        switch phase {
        case .own, .group:
            if keepIsUnproven && (wideningBlocked || draft.vibratoScale >= keepLimit) {
                return PitchWobbleReadout(PitchWobbleCopy.cannotWiden)
            }
            return PitchWobbleReadout(PitchWobbleCopy.dotTip(keep: draft.vibratoScale))
        case .made, .handedOff:
            return madeWords()
        }
    }

    /// Your wobble, in words. "Smoothed flat" only at keep 0: with the 20 c
    /// report floor a ±40 c wobble already reads `.noWobble` near keep 0.45,
    /// and calling that flat would be false.
    func ownWords(played: PitchWobbleReading?) -> String {
        typealias C = PitchWobbleCopy
        let keep = draft.vibratoScale
        if keep == 0 { return C.smoothedFlat }
        let coversPitch = PitchWobbleEstimate.response(pitchHz: stored.detectedHz) != nil
        if case .wobble(let rate, let depth, _, _)? = played {
            return C.yourWobble(heardRateHz: rate / stretchRatio,
                                depthCents: coversPitch ? depth : nil)
        }
        if keep == 1 {
            switch sung {
            case .unmeasurable(.tooUneven)?:
                return C.tooUnevenToMeasure
            case .unmeasurable?, nil:
                return C.tooShortToMeasure
            case .wobble(let rate, let depth, _, _)?:
                return C.yourWobble(heardRateHz: rate / stretchRatio,
                                    depthCents: coversPitch ? depth : nil)
            case .noWobble?:
                return C.noWobbleToMeasure
            }
        }
        return keep < 1 ? C.narrower : C.wider
    }

    /// A new wobble, in words: the ASKED heard rate and width (§9.3).
    func madeWords() -> PitchWobbleReadout {
        typealias C = PitchWobbleCopy
        let heard = heardRateHz
        if heard > NoteVibratoLimits.heardRateCeilingHz + 1e-9 {
            return PitchWobbleReadout(C.tooFastToPlay(heardRateHz: heard), isWarning: true)
        }
        let ceiling = PitchWobbleGesture.heardRateCeiling(stretchRatio: stretchRatio)
        var speedNote = ""
        if heard >= ceiling - 1e-9 {
            speedNote = ceiling < NoteVibratoLimits.heardRateCeilingHz - 1e-9
                ? C.fastestOnASlowedClip : C.fastestThatPlaysCleanly
        } else if speedMoved && abs(heard - PitchWobbleGesture.heardRateFloor) < 1e-9 {
            speedNote = C.slowestThisGoes
        }
        let depth = draft.vibratoDepthCents
        if depth == 0 {
            let fromNothing = start == .made(fromNothing: true)
            if phase == .made && fromNothing && !speedMoved && stored.vibratoRateHz == 0 {
                return PitchWobbleReadout(C.noWobbleToMeasure)
            }
            return PitchWobbleReadout(C.newWobbleNoneYet(heardRateHz: heard, speedNote: speedNote))
        }
        return PitchWobbleReadout(C.newWobble(heardRateHz: heard, speedNote: speedNote,
                                              depthCents: depth,
                                              replacesYourOwn: phase == .handedOff))
    }
}

// MARK: - Every word the Wobble tool and the dot draw (one home)

/// Every user-facing string of the Wobble tool and the dot, verbatim from the
/// design (§4.3, §5.3, §5.5, §9.2, §18.3; unpitched-notes §4; natural tuning
/// §3b). Novice words: no unit the product cannot back, never blaming the
/// singer. Drawn, never tooltips (V13: `view.capture` cannot see a tooltip).
public enum PitchWobbleCopy {

    // MARK: Help (§4.3, §5.3)

    /// The first sentence of the drawn help: the layout's own directions.
    public static func helpDirections(_ layout: PitchWobbleHandleLayout) -> String {
        switch layout {
        case .sidewaysIsSpeed:
            return "Drag up for a wider wobble, down for a flatter one, sideways for faster or slower."
        case .sidewaysIsWidth:
            return "Drag a note right to widen its wobble, left to smooth it flat. "
                + "Drag up or down for a faster or slower wobble."
        case .twoHandles:
            return "Drag the ↕ knob up to widen a note's wobble, down to smooth it flat. "
                + "Drag the ↔ knob sideways for a faster or slower wobble."
        }
    }

    public static let helpPianoKey = "100 cents is one piano key."
    /// Only once the Shape tool (C5b) exists (§3).
    public static let helpHoldCommand = "Hold ⌘ to draw instead."
    public static let helpLetGo = "Let go to hear it."
    /// `twoHandles` on a blob narrower than 40 pt (§4.3).
    public static let zoomInForTwoHandles = "Zoom in to change this note's wobble"

    // MARK: Refusals, drawn in `PanelRefusalLine` (§5.5)

    /// Basis `.estimate`, the contour not answered yet.
    public static let refusedWhileMatching =
        "Changing a wobble needs the app's analysis of this recording. One moment."
    /// Basis `.estimate`, the contour unavailable or from another generation.
    public static let refusedNoAnalysis =
        "The app couldn't analyse this recording, so this note's wobble can't be changed. "
            + "Its pitch can still be moved."

    // MARK: Your wobble (§9.2, amended by §18.3)

    public static let smoothedFlat = "Your wobble: smoothed flat"
    public static let narrower = "Your wobble: narrower"
    public static let wider = "Your wobble: wider"
    /// §18.3, `.tooFewSamples` or `.tooShort`, idle.
    public static let tooShortToMeasure =
        "This note is too short to measure its wobble. Drag down to smooth it."
    /// §18.3, `.tooUneven` (the scan edge included), idle.
    public static let tooUnevenToMeasure =
        "This note's pitch slides around rather than wobbling evenly. Drag down to smooth it."
    /// §18.3 Defect 2: dragging up where widening is not allowed; also the
    /// dot's tip at that cap.
    public static let cannotWiden =
        "As you sang it. This note is too short to make its wobble wider."
    /// §18.3: the handoff refused (short or uneven, not yet flat).
    ///
    /// W7-NTU (2026-10-04, by grant): 11 characters shorter than §18.3's
    /// wording ("first" and the second "drag" dropped; the steps and their
    /// order are unchanged). It is the palette's readout while it shows, and
    /// at 95 characters (588 pt, MEASURED) it left the Wobble help 281 pt at
    /// the 1208 pt floor beside four slots: three lines in a two-line box. At
    /// 84 (520 pt) the help has 349 pt, two lines, the same room as beside
    /// `tooUnevenToMeasure`. `PitchEditorPaletteFitTests.wobbleHelpFitsAtTheFloor`
    /// measures it, with the old wording as its control.
    public static let handoffRefused =
        "To change its speed, drag down to smooth it flat, then sideways to add a new wobble."
    /// §9.2 / §18.3: `.noWobble` — "the app can measure", never "no wobble":
    /// a singer's wobble under the 20 c report floor is real and unmeasured.
    public static let noWobbleToMeasure = "No wobble the app can measure. Drag up to add one."
    /// Natural tuning §3b: a selection's speed axis.
    public static let speedOneNoteAtATime = "Speed works on one note at a time"
    /// §9.2: on a note that also carries a C5b drawn shape.
    public static let drawnChangesStayOnTop = " (your drawn changes stay on top)"

    /// `Your wobble: about 5.5 per second, about 40 cents each way`, or the
    /// speed alone where no measured block covers the pitch (§18.3's row):
    /// `Your wobble: about 5.5 per second`.
    public static func yourWobble(heardRateHz: Double, depthCents: Double?) -> String {
        let speed = "Your wobble: about \(rate(heardRateHz)) per second"
        guard let depthCents else { return speed }
        return speed + ", about \(width(depthCents)) cents each way"
    }

    // MARK: A new wobble (§9.2)

    public static let fastestThatPlaysCleanly = " (the fastest that plays cleanly)"
    public static let fastestOnASlowedClip = " (the fastest possible on this slowed-down clip)"
    public static let slowestThisGoes = " (the slowest this control goes)"
    public static let mostThisAllows = " (the most this control allows)"
    public static let replacesYourOwn = " (replaces most of your own)"

    /// `New wobble: 5.5 per second, 30 cents each way`, with the ceiling notes
    /// after the number they qualify and `(replaces most of your own)` after a handoff.
    public static func newWobble(heardRateHz: Double, speedNote: String, depthCents: Double,
                                 replacesYourOwn: Bool) -> String {
        let atMost = depthCents >= NoteSegment.vibratoDepthCentsRange.upperBound - 1e-9
        return "New wobble: \(rate(heardRateHz)) per second\(speedNote), "
            + "\(width(depthCents)) cents each way\(atMost ? mostThisAllows : "")"
            + (replacesYourOwn ? self.replacesYourOwn : "")
    }

    /// `New wobble: 6.2 per second, none yet. Drag up to add it.`
    public static func newWobbleNoneYet(heardRateHz: Double, speedNote: String) -> String {
        "New wobble: \(rate(heardRateHz)) per second\(speedNote), none yet. Drag up to add it."
    }

    /// The red state (§9.2): heard above 8 after a clip-speed change.
    /// `New wobble: 9.6 per second: too fast to play cleanly at this clip's speed`
    public static func tooFastToPlay(heardRateHz: Double) -> String {
        "New wobble: \(rate(heardRateHz)) per second: too fast to play cleanly at this clip's speed"
    }

    // MARK: The dot's tip (unpitched-notes §4 — the user's own wording)

    /// `Wobble kept: 30% of how you sang it` · `As you sang it (100%)` ·
    /// `Smoothed flat (a little of your own movement may remain)` ·
    /// `Wobble widened to 130%`, by the keep's whole percent.
    public static func dotTip(keep: Double) -> String {
        let percent = Int((keep * 100).rounded())
        if percent <= 0 { return "Smoothed flat (a little of your own movement may remain)" }
        if percent == 100 { return "As you sang it (100%)" }
        if percent < 100 { return "Wobble kept: \(percent)% of how you sang it" }
        return "Wobble widened to \(percent)%"
    }

    // MARK: Numbers (§9.4)

    /// A heard rate, one decimal.
    static func rate(_ heardRateHz: Double) -> String {
        String(format: "%.1f", heardRateHz)
    }

    /// A width, to the nearest 5 cents.
    static func width(_ cents: Double) -> String {
        String(format: "%.0f", PitchWobbleGesture.quantiseDepth(cents))
    }
}
