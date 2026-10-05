import CoreGraphics
import Foundation

// m23-ap interaction batch, item I0 — THE ONE PRESS ROUTER.
//
// Design record: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §3
// item 5, and the vibrato design's §4.2, which named the router and said
// whichever item landed first would build it. This batch landed first.
//
// ⚠️ **THE TWO DESIGNS SPELL IT DIFFERENTLY; THIS FILE USES THE INTERACTION
// BATCH'S NAMES.** The vibrato doc (§4.2) wrote
// `route(tool:modifiersAtMouseDown:hit:) -> PitchEditorGestureKind` with kinds
// `pitchDrag/timingDrag/brush/wobble/split`. The batch that builds it wrote
// `route(tool:modifiersAtPress:hit:) -> PitchEditorPressKind` with
// `noteDrag/band/cut/none`. Same router, one home: C2-5, C5a-4 and C5b-4 add
// their kinds (`edge`, `wobble`, `brush`) HERE, as new cases and new truth-table
// rows, never as a second router.
//
// ⭐⭐ **"DECIDED ONCE PER PRESS" IS A PROPERTY OF `PitchEditorPressTracker`,
// NOT OF THE VIEW.** The router is a pure function and cannot remember anything;
// the tracker asks it on a gesture's FIRST tick and stores the answer for the
// rest of that gesture, so a zoom, a table read-back or a tool switch that moves
// what is under the press point cannot turn a pitch drag into a cut halfway
// through. `PitchEditorGestureRouterTests` plants a tracker that re-asks every
// tick and watches it go red.

/// What is under a press, as the router needs to know it.
public enum PitchEditorPressHit: Sendable, Equatable {
    /// A note, by `NoteSegment.id` — what `PitchEditorModel.blob(at:)` found,
    /// with its hit slop and nearest-by-vertical rule.
    case note(UUID)
    /// The surface, with no note under the point.
    case empty
    /// The surface is drawing no notes at all (still analysing, nothing found,
    /// analysis refused): nothing on it can be pressed. This is the knife's and
    /// the drag's own precondition (`PitchEditorState.drawsNotes`, the guard
    /// every gesture path carried before I0), stated as an input so `.none` is a
    /// real row of the truth table rather than a dead case.
    case inert
    /// m23-ap C5a-4b — the Wobble tool's DOT on a note, by `NoteSegment.id`:
    /// within `PitchWobbleGesture.knobHitRadius` of the dot at the note's top
    /// centre. `PitchEditorModel.pressHit(at:)` reports it ONLY in the Wobble
    /// tool and only on a note that tool can grab, so every other row of the
    /// table sees exactly the hits it saw before. ⚠️ The dot's 12 pt radius
    /// reaches ABOVE the blob, past `hitSlop` — a press there is on the dot
    /// although `blob(at:)` finds no note, which is why this is a hit of its
    /// own and not a flag on `.note`.
    case dot(UUID)
}

/// What a press on the pitch editor's surface IS — decided ONCE, on the
/// gesture's first tick, and never re-decided (design §3 item 5).
public enum PitchEditorPressKind: Sendable, Equatable {
    /// Move tool, on a note: the note's pitch, once the press travels past the
    /// slop. Released within it, the press is a CLICK (`PianoRollGridPress`).
    case noteDrag(UUID)
    /// Move tool, on empty surface: a rubber band once promoted past the slop
    /// (I4 draws and applies it); a click within it.
    case band
    /// Split tool, anywhere on a live surface: the knife, at the PRESS point.
    /// The verdict (`PitchEditorModel.cutVerdict(at:)`) decides cut / refuse /
    /// "nothing to cut there" — the router never pre-empts it, so the click's
    /// refusals stay word for word what they were.
    case cut
    /// Nothing on the surface can be pressed (`PitchEditorPressHit.inert`).
    case none
    /// m23-ap C5a-4b — Wobble tool, on a note: that note's wobble, through the
    /// DOOR the press came in by (unpitched design §4): `.dot` (the top-centre
    /// knob: released within the slop it is ONE STEP) or `.drag` (anywhere else
    /// on the note: released within the slop it is the house click). Past the
    /// slop both are the same drag (`PitchWobbleSession`).
    case wobble(UUID, door: PitchWobbleDoor)
    /// m23-ap C5b-4b — ⌘ held AT THE PRESS, on a note, in a tool where ⌘ draws
    /// (`PitchEditorGestureRouter.commandDraws`: Move and Wobble): the FREEHAND
    /// BRUSH, starting on that note (design 2026-09-24 timing-and-freehand
    /// §5.5; vibrato design §4.2, "⌘ held at mouse-down is the C5b brush in
    /// every tool, Wobble included"). Past the slop the stroke begins at the
    /// press point and may cross into other notes (`PitchEditorModel.trackPress`
    /// drives it whole); released within the slop the press is the house CLICK
    /// (⌘ on a note toggles it), exactly what a ⌘-click did before the brush.
    case brush(UUID)
    /// W7-NTU U3 — Voice tool, on a note: that note's VOICE (natural tuning
    /// §1(f) item 2), once the press travels past the slop: a vertical drag,
    /// up brighter, down deeper, the pitch never moved
    /// (`PitchEditorModel.updateVoiceDrag`). Released within the slop it is
    /// the house CLICK, or on a DOUBLE-click the reset to as sung (the knob
    /// law, `PitchEditorGestureRouter.release`).
    case formantDrag(UUID)

    /// Stable machine tag for the `debug.pitchEditor` echo.
    public var key: String {
        switch self {
        case .noteDrag: return "noteDrag"
        case .band: return "band"
        case .cut: return "cut"
        case .none: return "none"
        case .wobble: return "wobble"
        case .brush: return "brush"
        case .formantDrag: return "formantDrag"
        }
    }

    /// The pressed note, for `.noteDrag`, `.wobble`, `.brush` and
    /// `.formantDrag`.
    public var noteID: UUID? {
        switch self {
        case .noteDrag(let id), .wobble(let id, _), .brush(let id), .formantDrag(let id): return id
        case .band, .cut, .none: return nil
        }
    }

    /// The Wobble tool's door, for `.wobble` (the echo's `press.door`).
    public var wobbleDoor: PitchWobbleDoor? {
        if case .wobble(_, let door) = self { return door }
        return nil
    }
}

/// THE ONE mapping from a press to what it means.
public enum PitchEditorGestureRouter {

    /// What a press means.
    ///
    /// - Parameters:
    ///   - tool: the palette's engaged tool AT PRESS.
    ///   - modifiersAtPress: the chord at press (⇧/⌘, `ArrangeClickModifiers`,
    ///     the house click chord). ⭐ m23-ap C5b-4b — **⌘ IS THE ONE KEY A KIND
    ///     DEPENDS ON, AND ONLY ON A NOTE**: ⌘ on a note (or the Wobble tool's
    ///     dot) in a tool where ⌘ draws (`commandDraws`) is the BRUSH. ⇧ changes
    ///     no kind; ⌘ on empty surface is still the band (its click places the
    ///     playhead, I5); the knife ignores every chord. The truth table pins
    ///     each of those as a literal row. Still designed and not built: a
    ///     ⌘-press on an edge zone is C2-5's edge drag (design §14 (c)(i): the
    ///     edge beats ⌘), a new row here when it lands. ⌥ is deliberately NOT
    ///     here: it is read PER TICK (free pitch, C1), never decided at press. ⌃
    ///     is not here either: macOS turns a ⌃-press into the secondary click,
    ///     which is the context menu's (I7b), not a drag.
    ///   - hit: what is under the press point.
    ///
    /// m23-ap C5a-4b — the Wobble tool's rows: on a note, `.wobble` through the
    /// door the hit names (`.dot` or anywhere else on the note, `.drag`); on
    /// empty surface a band, as in the Move tool, so a person can still select
    /// in the tool they are in. A `.dot` hit is only ever reported in the Wobble
    /// tool (`PitchEditorModel.pressHit`); the Move and Split rows answer it as
    /// they answer the note it sits on, so the table stays total.
    ///
    /// W7-NTU U3 — the Voice tool's rows (natural tuning §1(f) item 2): on a
    /// note, `.formantDrag`, or the brush with ⌘ (⌘ draws in every tool but
    /// the knife); on empty surface a band, as in the Move and Wobble tools.
    /// A `.dot` hit never reaches it (only the Wobble tool reports one), and
    /// it answers one as the note the dot sits on, so the table stays total.
    public static func route(tool: PitchEditorTool, modifiersAtPress: ArrangeClickModifiers,
                             hit: PitchEditorPressHit) -> PitchEditorPressKind {
        // C5b-4b — decided with the tool, never after it: the knife's rows
        // below never see ⌘ because `commandDraws` is false for it.
        let draws = modifiersAtPress.contains(.command) && commandDraws(in: tool)
        switch (tool, hit) {
        case (_, .inert): return .none
        case (.scissors, _): return .cut
        case (.pointer, .note(let id)), (.pointer, .dot(let id)):
            return draws ? .brush(id) : .noteDrag(id)
        case (.pointer, .empty): return .band
        case (.wobble, .note(let id)): return draws ? .brush(id) : .wobble(id, door: .drag)
        case (.wobble, .dot(let id)): return draws ? .brush(id) : .wobble(id, door: .dot)
        case (.wobble, .empty): return .band
        case (.voice, .note(let id)), (.voice, .dot(let id)):
            return draws ? .brush(id) : .formantDrag(id)
        case (.voice, .empty): return .band
        }
    }

    /// m23-ap C5b-4b — whether ⌘ held at a press DRAWS in `tool`: the Move and
    /// Wobble tools (vibrato design §4.2: "⌘ held at mouse-down is the C5b
    /// brush in every tool, Wobble included"), and NOT the Split tool. The
    /// knife is a click by definition and lands where the press began (the C3
    /// rule); a ⌘-press there stays a cut, so a person reaching for a stroke
    /// with the knife engaged never has it turned into a drawing, and never
    /// the other way round. ONE home: the router's rows, the palette's help
    /// and the brush band all ask this.
    ///
    /// W7-NTU U3 — the Voice tool draws too: "⌘ held at mouse-down is the C5b
    /// brush in every tool" (vibrato design §4.2, repeated for the Drift tool
    /// in natural tuning §3), and the knife stays the one exception.
    public static func commandDraws(in tool: PitchEditorTool) -> Bool {
        switch tool {
        case .pointer, .wobble, .voice: return true
        case .scissors: return false
        }
    }

    /// Pointer travel, in points, that turns a press into a gesture: RADIAL, and
    /// the roll's band-promotion threshold borrowed rather than re-typed
    /// (`PianoRollMarquee.dragSlop`, compared with `>=` as the roll's
    /// `advanceMarquee` does). Design §3 names this slop for both the band and
    /// the note press; the roll's separate `moveCommitSlop` answers a question
    /// this pane has never had a shipped answer to.
    public static let slop: CGFloat = PianoRollMarquee.dragSlop

    /// Whether `point` is far enough from `origin` to promote a press.
    public static func hasTravelled(from origin: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) >= slop
    }

    /// What releasing a press does, from the kind decided at its first tick and
    /// whether it ever travelled past the slop.
    ///
    /// - A press that never travelled is a CLICK, resolved by the roll's own
    ///   table, verbatim (`PianoRollGridPress.release`, the chord read AT RELEASE
    ///   as that table's doc requires): plain on a note selects it, ⇧/⌘ on a note
    ///   toggles it, plain on empty deselects, ⌘ on empty places the playhead,
    ///   ⇧ on empty does nothing. ⭐ In I0 nothing ACTS on a click yet — I4 owns
    ///   selection and I5 the playhead — but the answer is computed and reported
    ///   now, so those items plug into a seam that already routes.
    /// - The knife is a click by definition and ignores travel: it lands where
    ///   the press BEGAN ("a hand that slipped two points during it did not mean
    ///   to move the knife", the C3 rule).
    ///
    /// m23-ap C5a-4b — a `.wobble` press resolves through the dot's own input
    /// table (`PitchWobbleGesture.release`, unpitched design §4): travelled is
    /// the end of the drag; a DOT press released inside the slop is one step,
    /// bigger or — with ⌥ held AT RELEASE (`optionAtRelease`) — smaller; any
    /// other press on the note released inside the slop is the house click.
    /// ⌥ rides in its own argument because `ArrangeClickModifiers` carries ⇧
    /// and ⌘ only (see `route`); it defaults to false, so every caller before
    /// C5a-4b reads exactly what it did.
    ///
    /// m23-ap C5b-4b — a `.brush` press that travelled is the end of the stroke
    /// (`endBrush`: one commit for every note it drew on, none for a stroke
    /// that changed nothing); one that never left the slop is the house click,
    /// read with the chord AT RELEASE like every other click.
    ///
    /// W7-NTU U3 — a `.formantDrag` press that travelled ends the Voice drag
    /// (`endFormantDrag`: at most one commit). One that never left the slop is
    /// the house click, unless it is the SECOND click of a double-click
    /// (`clickCount` ≥ 2, the mouse-up's own count), which puts the note's
    /// Voice back as sung (`formantReset`, the knob law's double-click).
    /// Travel beats the count: a double-click that dragged is a drag.
    /// `clickCount` defaults to 1, so every caller before U3 reads as it did,
    /// and no other kind reads it.
    public static func release(kind: PitchEditorPressKind, travelled: Bool, origin: CGPoint,
                               modifiersAtRelease: ArrangeClickModifiers,
                               optionAtRelease: Bool = false,
                               clickCount: Int = 1) -> PitchEditorReleaseAction {
        switch kind {
        case .none:
            return .nothing
        case .cut:
            return .cut(at: origin)
        case .noteDrag(let id):
            return travelled
                ? .endNoteDrag(id)
                : .click(PianoRollGridPress.release(noteID: id, modifiers: modifiersAtRelease))
        case .band:
            return travelled
                ? .endBand
                : .click(PianoRollGridPress.release(noteID: nil, modifiers: modifiersAtRelease))
        case .wobble(let id, let door):
            switch PitchWobbleGesture.release(door: door, travelled: travelled,
                                              optionHeld: optionAtRelease) {
            case .endDrag: return .endWobble(id)
            case .step(let bigger): return .wobbleStep(id, bigger: bigger)
            case .click: return .click(PianoRollGridPress.release(noteID: id, modifiers: modifiersAtRelease))
            }
        case .brush(let id):
            return travelled
                ? .endBrush(id)
                : .click(PianoRollGridPress.release(noteID: id, modifiers: modifiersAtRelease))
        case .formantDrag(let id):
            if travelled { return .endFormantDrag(id) }
            if clickCount >= 2 { return .formantReset(id) }
            return .click(PianoRollGridPress.release(noteID: id, modifiers: modifiersAtRelease))
        }
    }
}

/// What a release does — the ONE value `PitchEditorView.dragEnded` switches
/// over, so the gesture's end is decided by the press it ends and never by
/// whatever tool happens to be engaged at mouse-up.
public enum PitchEditorReleaseAction: Sendable, Equatable {
    /// A pitch drag that travelled: commit it (`PitchEditorModel.endPitchDrag`,
    /// at most one write, none for a no-op).
    case endNoteDrag(UUID)
    /// A band that travelled: I4 applies its final selection. Nothing in I0.
    case endBand
    /// The knife, at the press point (`PitchEditorModel.splitNote(at:)`).
    case cut(at: CGPoint)
    /// A press that never travelled past the slop: the house click table's
    /// answer. Nothing acts on it in I0 (see `PitchEditorGestureRouter.release`).
    case click(PianoRollGridRelease)
    /// Nothing: an inert surface, or no press in flight.
    case nothing
    /// m23-ap C5a-4b — a wobble drag that travelled: commit it
    /// (`PitchEditorModel.endWobbleDrag`, at most one write, none for a
    /// gesture that plays like the stored note).
    case endWobble(UUID)
    /// m23-ap C5a-4b — a click on the Wobble tool's dot: ONE step, bigger, or
    /// smaller with ⌥ (`PitchEditorModel.stepWobble`, one write).
    case wobbleStep(UUID, bigger: Bool)
    /// m23-ap C5b-4b — a brush stroke that travelled, begun on this note:
    /// commit it (`PitchEditorModel.endBrush`, at most one write for every
    /// note the stroke drew on, none for a stroke that changed nothing).
    case endBrush(UUID)
    /// W7-NTU U3 — a Voice drag that travelled: commit it
    /// (`PitchEditorModel.endVoiceDrag`, at most one write, none for a drag
    /// that ends on the stored value).
    case endFormantDrag(UUID)
    /// W7-NTU U3 — a double-click on a note in the Voice tool: its Voice back
    /// as sung (`PitchEditorModel.resetVoice`, one write, none when it
    /// already is).
    case formantReset(UUID)

    /// Stable machine tag for the `debug.pitchEditor` echo.
    public var key: String {
        switch self {
        case .endNoteDrag: return "endNoteDrag"
        case .endBand: return "endBand"
        case .cut: return "cut"
        case .click: return "click"
        case .nothing: return "nothing"
        case .endWobble: return "endWobble"
        case .wobbleStep: return "wobbleStep"
        case .endBrush: return "endBrush"
        case .endFormantDrag: return "endFormantDrag"
        case .formantReset: return "formantReset"
        }
    }
}

/// One press, from its first tick to its release.
public struct PitchEditorPress: Sendable, Equatable {
    /// What the press IS — the router's answer at the first tick, and a `let`.
    public let kind: PitchEditorPressKind
    /// Where it began, in the surface's CONTENT space (`DragGesture`'s
    /// `startLocation` on the content view). Also this press's identity: a
    /// gesture's start location is constant for its whole life.
    public let origin: CGPoint
    /// The chord at press — what the router was asked with.
    public let modifiersAtPress: ArrangeClickModifiers
    /// Whether the pointer has EVER travelled `PitchEditorGestureRouter.slop`
    /// from `origin`. Latched: a drag that goes out and comes back is still a
    /// drag, exactly as the roll's promoted band stays a band.
    public fileprivate(set) var isPromoted: Bool

    public init(kind: PitchEditorPressKind, origin: CGPoint,
                modifiersAtPress: ArrangeClickModifiers, isPromoted: Bool = false) {
        self.kind = kind
        self.origin = origin
        self.modifiersAtPress = modifiersAtPress
        self.isPromoted = isPromoted
    }
}

/// What one pointer tick did to the press in flight.
public struct PitchEditorPressTick: Sendable, Equatable {
    /// The press's kind — the same value on every tick of one gesture.
    public let kind: PitchEditorPressKind
    /// This tick CREATED the press: it is the one tick on which the router was
    /// asked.
    public let isFirst: Bool
    /// This tick crossed the slop (at most one tick per press).
    public let didPromote: Bool
    /// The press is past the slop, now or on an earlier tick.
    public let isPromoted: Bool

    public init(kind: PitchEditorPressKind, isFirst: Bool, didPromote: Bool, isPromoted: Bool) {
        self.kind = kind
        self.isFirst = isFirst
        self.didPromote = didPromote
        self.isPromoted = isPromoted
    }
}

/// The press state machine: decides ONCE per press, tracks travel, resolves the
/// release. A pure value — held by `PitchEditorModel`, driven by the view's two
/// gesture callbacks and by the debug tier's staged steps through the SAME two
/// callbacks, and tested headlessly.
public struct PitchEditorPressTracker: Sendable, Equatable {
    /// The press in flight, or `nil`.
    public private(set) var current: PitchEditorPress?

    public init() {}

    /// One pointer tick of a gesture that began at `start` and is now at
    /// `location` (both content space).
    ///
    /// The FIRST tick of a gesture asks the router — `hit` is evaluated at
    /// `start` then, and never again for this press. Every later tick of the SAME
    /// gesture (same `start`) only measures travel.
    ///
    /// ⚠️ **A DIFFERENT `start` IS A NEW GESTURE, AND THAT IS NOT A RE-DECISION.**
    /// `DragGesture.onEnded` is not guaranteed (a window resigning key, a
    /// teardown), so a press can be left behind; the next gesture's first tick
    /// then arrives with its own start location and is routed afresh, instead of
    /// inheriting a stale kind. Within one gesture `start` never changes.
    public mutating func tick(start: CGPoint, location: CGPoint, tool: PitchEditorTool,
                              modifiers: ArrangeClickModifiers,
                              hit: (CGPoint) -> PitchEditorPressHit) -> PitchEditorPressTick {
        if var press = current, press.origin == start {
            let didPromote = !press.isPromoted
                && PitchEditorGestureRouter.hasTravelled(from: press.origin, to: location)
            if didPromote { press.isPromoted = true }
            current = press
            return PitchEditorPressTick(kind: press.kind, isFirst: false,
                                        didPromote: didPromote, isPromoted: press.isPromoted)
        }
        let kind = PitchEditorGestureRouter.route(tool: tool, modifiersAtPress: modifiers,
                                                  hit: hit(start))
        // A first tick that ALREADY travelled (a late-delivered flick) creates
        // and promotes the press in one step, so neither half is lost.
        let travelled = PitchEditorGestureRouter.hasTravelled(from: start, to: location)
        current = PitchEditorPress(kind: kind, origin: start, modifiersAtPress: modifiers,
                                   isPromoted: travelled)
        return PitchEditorPressTick(kind: kind, isFirst: true, didPromote: travelled,
                                    isPromoted: travelled)
    }

    /// The gesture that began at `start` ended at `location`: what the release
    /// does, and the press is over. `.nothing` when no press is in flight, or
    /// when the one in flight belongs to a DIFFERENT gesture (a stale press whose
    /// release was dropped — acting on it would commit a gesture that is over).
    ///
    /// `optionAtRelease` is ⌥ at the release (C5a-4b: the dot's smaller step);
    /// defaulted, so a caller that never had one reads exactly as before.
    /// `clickCount` is the mouse-up's click count (W7-NTU U3: the Voice tool's
    /// double-click reset), defaulted to 1 for the same reason.
    public mutating func release(start: CGPoint, at location: CGPoint,
                                 modifiers: ArrangeClickModifiers,
                                 optionAtRelease: Bool = false,
                                 clickCount: Int = 1) -> PitchEditorReleaseAction {
        guard let press = current else { return .nothing }
        current = nil
        guard press.origin == start else { return .nothing }
        let travelled = press.isPromoted
            || PitchEditorGestureRouter.hasTravelled(from: press.origin, to: location)
        return PitchEditorGestureRouter.release(kind: press.kind, travelled: travelled,
                                                origin: press.origin,
                                                modifiersAtRelease: modifiers,
                                                optionAtRelease: optionAtRelease,
                                                clickCount: clickCount)
    }

    /// The gesture was abandoned (the pane went away, a clip switched).
    public mutating func cancel() { current = nil }

    /// ESCAPE cancelled the press in flight while the pointer is STILL DOWN
    /// (m23-ap I4, `EditorEscapeRung.cancelGesture`). Unlike `cancel()`, the
    /// press stays TRACKED — as an inert `.none` press at the same origin — so
    /// the rest of THIS gesture's ticks (same `start`) find it and do nothing,
    /// and its release resolves to `.nothing`. Forgetting it instead would let
    /// the very next tick route afresh at the same start point: a cancelled
    /// pitch drag would restart itself one tick later. The roll's `.cancelled`
    /// gesture state (m18-i), as a value. No press in flight: nothing to do.
    public mutating func abandon() {
        guard let press = current else { return }
        current = PitchEditorPress(kind: .none, origin: press.origin,
                                   modifiersAtPress: press.modifiersAtPress,
                                   isPromoted: press.isPromoted)
    }
}
