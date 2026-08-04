import Foundation

/// The ONE home for "**which editing surface is the user working in?**" — and the
/// only place that question is answered.
///
/// WHY THIS EXISTS (m23-al). The m21-c ⌘+/⌘−/⌘0 router used to read
/// `AppModel.pianoRollEditorFocused`, and that flag CANNOT carry the question.
/// Three claims, each verifiable in source, and the third is the whole argument:
///
///  - **C1 — there are TWO competing `@FocusState` owners in an ancestor/
///    descendant pair, driven by two independent event streams.** The arrange
///    workspace root (`ContentView.swift:1620`, bound `:1625`) asserts focus from
///    `.onChange(of: model.arrangeKeyFocusNonce)` (`ContentView.swift:1695`),
///    which fires ONCE PER CLICK (`DAWProApp.swift:694` / `:743`). The piano roll
///    (`PianoRollView.swift:143`, bound `:268`) asserts focus from
///    `.onAppear` (`:275`), which fires ONCE PER REBUILD (`.id(clip.id)` at
///    `ContentView.swift:661`). `ContentView.swift:453-461` records that this
///    exact file was bitten once before by "three independent `@FocusState`s all
///    asserting focus on the same nonce, i.e. a focus fight" — this was the
///    SECOND instance, not a novel risk.
///  - **C2 — `pianoRollEditorFocused` is a pure REPORT of who won.** Its only
///    writer is `ContentView.swift:646`, fed from `PianoRollView.swift:279` and
///    `:318`. Nothing in `ProjectStore`, `AppModel` or `PanelLayoutModel`
///    determines it.
///  - **C3 — therefore no consumer that reads it can be deterministic**,
///    whatever the arbitration order turns out to be.
///
/// MEASURED (`scripts/gates/_m23al-focus-probe.mjs`, 5 sequences × 12 clicks, 3
/// runs, `settling=0` on every row): across clip SWITCHES the flag alternates
/// 6 true / 6 false; across 12 clicks on ONE clip it reads `true` exactly ONCE —
/// the click that opens the roll — and `false` eleven times. So clicking a MIDI
/// clip TWICE left ⌘+ zooming the arrange for the rest of the session.
///
/// ⚠️ WHAT IS **NOT** MEASURED, AND MUST NOT BE WRITTEN DOWN AS IF IT WERE: the
/// rule SwiftUI uses to arbitrate between the two owners. The plausible reading —
/// "writing `true` to an already-`true` `@FocusState` is not a change and
/// arbitrates nothing" — fits the data but was never measured, and on a switch
/// click BOTH the nonce write and the incoming instance's `.onAppear` fire, with
/// an ORDER that is SwiftUI's and that this tree cannot observe (m23-bw). The
/// ordering rule stays UNDETERMINED. **That is fine, and it is the point of this
/// design: because the fix removes the flag from every decision path, the
/// ordering rule does not need to be determined.** Any design whose correctness
/// argument requires knowing it is the wrong design.
///
/// SO THE FIX IS NOT "STABILISE THE FLAG". It is to answer a different,
/// higher-level question from app state the app itself writes:
///
/// > **The active editor surface is `.pianoRoll` iff the piano roll is open AND
/// > the most recent user engagement was inside the roll. Otherwise `.arrange`.**
///
/// LAST-ENGAGED WINS — and that is a product decision with two in-tree citations
/// that appear to disagree, so both are named here rather than one being quietly
/// preferred:
///
///  - `DAWProApp.swift:468-470` ("the roll self-focuses on appear and opens for
///    ANY single selected MIDI clip, so `pianoRollEditorFocused` alone is already
///    true when the user has merely clicked a clip") is **DESCRIPTIVE**. It sits
///    inside the doc comment for a DIFFERENT property and argues why focus makes
///    a bad nudge guard. It says what the flag IS, not what routing SHOULD do.
///  - `PianoRollNoteSelectionBridge.swift:51-53` ("routing ⌘+/⌘−/⌘0 to whichever
///    zoom the user most recently engaged") is **NORMATIVE about m21-c**, and is
///    the only sentence in the tree that states the intended routing rule.
///
/// THE ACCEPTED CONSEQUENCE, NAMED UP FRONT: clicking a MIDI clip in the arrange
/// opens the roll and LEAVES THE ARRANGE ACTIVE, so ⌘+ zooms the arrange. To zoom
/// the roll, click in it first. That is what "most recently engaged" means, it
/// matches Logic's active-area model, and it makes the whole app give ONE answer
/// to "which surface is the user working in" — the same gesture that gives the
/// arrange DELETE (m23-y) gives it ⌘+. Neither surface loses reachability: the
/// arrange keeps its toolbar cluster and pinch, the roll keeps its header cluster
/// (`PianoRollView.swift:782/790`) and pinch (`:826`).
///
/// THE ALTERNATIVE, should it ever be overruled: "opening the roll engages it" is
/// a ONE-LINE change inside `resolve` (drop the `lastEngaged` term, or add an
/// `openedBy` one), with one test table to update. That the overrule costs one
/// line in one file is the entire point of building a home. **Do not scatter the
/// choice.**
///
/// WHAT THIS HOME MUST NOT OWN — each of these has already been tried somewhere
/// in this tree and each is pinned by `EditorSurfaceOwnershipSiteTests`:
///  - **any `@FocusState`, any SwiftUI focus concept, any `NSResponder` notion.**
///    A focus term added to `resolve` would be the m23-al bug with more steps.
///  - **which keystroke goes where.** DELETE and ←/→/↑/↓ arbitration stays in
///    `handleArrangeDeleteKey`, `handleArrangeNudgeKey`'s six guards, and the
///    roll's own `.onKeyPress(.delete)`. Migrating those here is m23-al-3 and is
///    deliberately NOT in this arc.
///  - **zoom ARITHMETIC.** `ArrangeZoom` / `PianoRollZoom` keep the ladders; this
///    says only WHICH.
///  - **persistence.** Engagement is session state and must never reach
///    `PanelLayoutModel` or a project file. A restored "the roll was engaged" with
///    no roll open would be a latched lie — the failure
///    `PianoRollNoteSelectionBridge.clear()` exists to prevent.
public enum EditorSurface: String, Sendable, Equatable, CaseIterable {
    case arrange
    case pianoRoll
}

/// A RESOLVED verdict about which surface is active, carrying the term that
/// decided it.
///
/// ⚠️ `fileprivate init` — AND ITS HONEST LIMIT. The only way to HOLD one of
/// these is to have called `EditorSurfaceRouter.resolve`, which makes a
/// divergent second computation of the RULE unrepresentable outside this file
/// (the `ArrangeDropSnap.ResolvedDropBeat` property). It does **not** prevent
/// somebody writing `if openEditorClip != nil { zoomPianoRollIn() }` — a
/// divergent boolean that never constructs this type. Closing THAT gap is the
/// job of the reader site test (`EditorSurfaceOwnershipSiteTests`), not of this
/// initializer, and the two are a pair. Do not overstate either one.
public struct ActiveEditorSurface: Sendable, Equatable {

    /// WHICH TERM DECIDED, in the order `resolve` applies them. Echoed on the
    /// wire so a red gate leg says which term was not in the state it assumed —
    /// a bare `.arrange` cannot tell "the Mix console is up" from "no clip is
    /// open" from "the user last clicked the arrange", and those are three
    /// different bugs.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// The Mix console is up — no `PianoRollView` is MOUNTED at all.
        case notArrangeWorkspace
        /// Arrange workspace, but no MIDI clip is open.
        case noRollOpen
        /// Roll on screen; the last engagement was the arrange.
        case engagedArrange
        /// Roll on screen; the last engagement was the roll.
        case engagedRoll
    }

    public let surface: EditorSurface
    public let reason: Reason

    fileprivate init(_ surface: EditorSurface, _ reason: Reason) {
        self.surface = surface
        self.reason = reason
    }
}

/// Resolves the active editor surface. Pure, total, `nonisolated`.
///
/// The actor-freedom is itself the structural claim that this rule needs no app,
/// no view and no actor (the `WidenedArrangeSelectionDropTests` precedent) — it
/// is a function of three plain values, which is why it can be swept exhaustively
/// in `EditorSurfaceRouterTests` while `DAWApp` has no test target at all.
public enum EditorSurfaceRouter {

    /// - Parameters:
    ///   - workspaceIsArrange: is the ARRANGE workspace live (as opposed to the
    ///     Mix console)?
    ///   - rollOpen: is a MIDI clip open in the piano roll (`openEditorClip !=
    ///     nil` — the tree's ONE rule for "the roll is on screen")?
    ///   - lastEngaged: the surface the user most recently acted inside.
    ///
    /// ⚠️ **THE WORKSPACE TERM IS NOT OPTIONAL AND IS THE EASIEST THING TO DROP.**
    /// `openEditorClip` (`DAWProApp.swift:1490-1498`) is derived purely from
    /// `selectedClipID` plus a store lookup and carries NO workspace term — but
    /// the editor pane is rendered inside `arrangeWorkspace`, so in the **Mix
    /// console** a MIDI clip can stay selected while no `PianoRollView` is
    /// mounted at all. Without this term a latched `lastEngaged == .pianoRoll`
    /// makes the router zoom a roll the user cannot see. The tree already treats
    /// this as a first-class guard rather than an afterthought:
    /// `handleArrangeNudgeKey` opens with `guard workspaceMode == .arrange`
    /// SEPARATELY from its `openEditorClip` term, and `ContentView.swift:1261-1264`
    /// records that the Mix workspace is a mutually exclusive branch. A home that
    /// silently drops a term two existing sites carry IS the divergence this home
    /// exists to prevent.
    ///
    /// `.arrange` (rather than a third "no surface" case) is the right Mix
    /// fallback: there is no mixer zoom, so ⌘+ zooming the arrange behind the
    /// console is the existing, harmless behaviour, and a third case would
    /// create a state every consumer had to handle for no benefit.
    ///
    /// A `Bool` and not a `WorkspaceMode`, and that is a MODULE BOUNDARY rather
    /// than laziness: `WorkspaceMode` is declared in `DAWApp`
    /// (`DAWProApp.swift:52`), which DAWAppKit must not depend on. The parameter
    /// is named `workspaceIsArrange` so a caller cannot pass the wrong polarity
    /// by accident.
    nonisolated public static func resolve(
        workspaceIsArrange: Bool,
        rollOpen: Bool,
        lastEngaged: EditorSurface
    ) -> ActiveEditorSurface {
        guard workspaceIsArrange else { return ActiveEditorSurface(.arrange, .notArrangeWorkspace) }
        guard rollOpen else { return ActiveEditorSurface(.arrange, .noRollOpen) }
        return lastEngaged == .pianoRoll
            ? ActiveEditorSurface(.pianoRoll, .engagedRoll)
            : ActiveEditorSurface(.arrange, .engagedArrange)
    }
}

/// The LATCH: which surface the user most recently engaged, and the only mutator
/// of it. The `PianoRollNoteSelectionBridge` / `AutomationPointSelectionBridge`
/// shape — a small observable object the views report INTO, held by `AppModel`.
///
/// Gesture LOCATION sets engagement. The views report gestures; this holds the
/// answer; `EditorSurfaceRouter.resolve` decides. Conflating the three is the bug
/// m23-al fixed.
@MainActor
@Observable
public final class EditorSurfaceEngagement {

    /// The surface the user most recently acted inside.
    ///
    /// NOT an `Optional`, deliberately: the app starts in the arrange, and
    /// "nobody has engaged anything yet" and "the arrange is engaged" have
    /// identical consequences — a `nil` would be a state no consumer could act on
    /// differently, i.e. a fourth state that exists only to be mapped away.
    public private(set) var lastEngaged: EditorSurface = .arrange

    /// ⚠️ **TRANSITIONS, NOT CALLS.** This counts how many times `lastEngaged`
    /// actually CHANGED. `arrangeKeyFocusNonce` (`DAWProApp.swift:694`) counts
    /// CALLS, and a reader who assumes the same shape will write a gate leg that
    /// cannot fail — engage the roll twice and this stays put, on purpose.
    public private(set) var transitionSeq = 0

    public init() {}

    /// Report that the user just acted inside `surface`.
    ///
    /// ⚠️ THE CHANGE-GUARD IS LOAD-BEARING, NOT AN OPTIMISATION.
    /// `PianoRollView.beginGesture` and `scrubDrag.onChanged` fire on every tick
    /// of every drag, and an unguarded write to an `@Observable` property
    /// invalidates every observer of this object on every one of them — a note
    /// drag would re-evaluate the app's whole observation graph at pointer rate.
    public func engage(_ surface: EditorSurface) {
        guard surface != lastEngaged else { return }
        lastEngaged = surface
        transitionSeq &+= 1
    }
}
