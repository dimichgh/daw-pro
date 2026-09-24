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
    /// The read-only vocal pitch editor (m23-ap Phase 2) — the SECOND bottom
    /// editor pane, a sibling of the roll rather than a mode of it.
    ///
    /// ⭐ **A THIRD CASE RATHER THAN A `pianoRoll` FLAG, FOR THE REASON §3.3 OF
    /// `docs/design/2026-09-22-pitch-editor-ui.md` GIVES:** the two panes edit
    /// incompatible models on incompatible axes (`[MIDINote]` at integer pitch
    /// vs `[NoteSegment]` at continuous `Double` midi), and every MIDI-shaped
    /// gate of the roll — ⌘A selects NOTES, Paste pastes NOTES, DELETE routes on
    /// `pianoRollWouldConsumeKey` — would be inherited wrongly by a mode flag.
    ///
    /// ⚠️ **WHAT DID NOT MOVE WITH IT, AND MUST NOT (design §3.6).**
    /// `pianoRollWouldConsumeKey`, `SelectAllMenuPolicy`,
    /// `ClipboardMenuPolicy.pasteMenuItem` and `DeleteMenuPolicy` all ask NOTE
    /// questions, and a pitch SEGMENT is not a note. They stay MIDI-only; ⌘A and
    /// DELETE *inside* the pitch editor are interaction questions that belong to
    /// the (still unwritten) §7, not to this enum.
    case pitchEditor
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
        /// An editor pane is on screen; the last engagement was the arrange.
        ///
        /// ⚠️ **SHARED BY BOTH PANES ON PURPOSE (m23-ap p2-b).** "Which pane the
        /// user is NOT working in" is one fact, and splitting it in two would
        /// invent a distinction no consumer can act on — the `SelectAllSurface`
        /// single-case argument. Which pane is open is answered by
        /// `OpenEditorSurface.Reason`, which is exactly what that verdict is for.
        case engagedArrange
        /// Roll on screen; the last engagement was the roll.
        case engagedRoll
        /// Pitch editor on screen; the last engagement was the pitch editor.
        case engagedPitchEditor
    }

    public let surface: EditorSurface
    public let reason: Reason

    fileprivate init(_ surface: EditorSurface, _ reason: Reason) {
        self.surface = surface
        self.reason = reason
    }
}

/// A RESOLVED verdict about which surface is **OPEN** — on screen and available
/// to be acted on — regardless of whether the user has engaged it yet (m34-d).
///
/// ═══ WHY A SECOND VERDICT RATHER THAN A CHANGE TO THE FIRST ═══
///
/// The user ruled on ⌘A 2026-08-30, verbatim: ***"Make it work whenever the
/// editor is open."*** `ActiveEditorSurface`'s banner names the alternative it
/// would take to obey that — *"'opening the roll engages it' is a ONE-LINE change
/// inside `resolve` (drop the `lastEngaged` term…)"* — and ⚠️ **THAT IS THE WRONG
/// LINE TO CHANGE, because the ruling is about ONE KEYSTROKE.** `resolve` also
/// routes ⌘+ / ⌘− / ⌘0; dropping its engagement term would silently hand the
/// roll every zoom the moment a clip opened, which nobody asked for and which
/// `EditorSurfaceOwnershipSiteTests` exists to notice. So the router now answers
/// **two** questions instead of one being bent to cover both:
///
///   `resolve`     → which surface is the user **WORKING IN**   (engagement)
///   `openSurface` → which surface is **OPEN IN FRONT OF THEM** (mount)
///
/// ⭐ **THEY ARE NOT INDEPENDENT AND MUST NOT DRIFT: `resolve` is IMPLEMENTED ON
/// TOP OF `openSurface`**, so the two workspace/roll-open terms are computed
/// once, in one place, and a future edit to either cannot move one verdict
/// without moving the other. Two verdicts, one set of terms.
///
/// WHY ⌘A GETS THIS ONE AND ITS TWO EDIT-MENU NEIGHBOURS DO NOT: see
/// `SelectAllMenuPolicy`'s banner. Delete and Cut/Copy route on
/// `pianoRollWouldConsumeKey` ("the roll is open **AND HOLDS A NOTE
/// SELECTION**"), which cannot express a select-all at all — that key exists to
/// be pressed when nothing is selected. Three items, three questions, three
/// terms; this is the third term.
public struct OpenEditorSurface: Sendable, Equatable {

    /// WHICH TERM DECIDED, in the order `openSurface` applies them.
    ///
    /// `ActiveEditorSurface.Reason`'s first two cases by the same names and for
    /// the same reason (a bare `.arrange` cannot tell "the Mix console is up"
    /// from "no clip is open" — two different bugs), MINUS the two engagement
    /// cases, which this verdict has no term for, PLUS the one it adds.
    ///
    /// ⚠️ A SEPARATE ENUM RATHER THAN A SHARED ONE, deliberately: sharing would
    /// give every consumer of this verdict two cases (`engagedArrange` /
    /// `engagedRoll`) that `openSurface` can never return, i.e. two states a
    /// `switch` must handle that are unreachable by construction. That is the
    /// `SelectAllSurface` single-case argument run the other way.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// The Mix console is up — no `PianoRollView` is MOUNTED at all.
        case notArrangeWorkspace
        /// Arrange workspace, but no MIDI clip is open.
        case noRollOpen
        /// A MIDI clip IS open in the roll. ⭐ **This is the state m34-d fixed:
        /// it is reached the instant the user clicks a clip in the arrange, one
        /// gesture BEFORE `resolve` would call the roll active.**
        case rollOpen
        /// An AUDIO clip is open in the pitch editor (m23-ap p2-b).
        ///
        /// ⚠️ **`noRollOpen` ABOVE NOW MEANS "NEITHER PANE IS OPEN", AND ITS
        /// NAME IS DELIBERATELY UNCHANGED** — the spelling is echoed by
        /// `debug.editorSurface` and pinned in `EditorSurfaceRouterTests`, and
        /// the standing wire rule is ADDITIVE ONLY, never rename a live string.
        /// A reader who needs the distinction has this case to read.
        case pitchEditorOpen
    }

    public let surface: EditorSurface
    public let reason: Reason

    /// `fileprivate`, with `ActiveEditorSurface`'s honest limit unchanged: this
    /// makes a divergent second computation of the RULE unrepresentable outside
    /// this file, and does **not** prevent somebody writing a bare
    /// `if openEditorClip != nil` that never constructs the type. The reader
    /// site census is the other half of that pair.
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
    ///   - pitchEditorOpen: is an AUDIO clip open in the pitch editor
    ///     (`openPitchEditorClip != nil` — m23-ap p2-b's one rule for "the pitch
    ///     editor is on screen")?
    ///
    ///     ⭐ **THE TWO PANE TERMS CANNOT BOTH BE TRUE IN THE APP, AND THAT IS
    ///     STRUCTURAL RATHER THAN ARBITRATED** (design §3.6): both accessors
    ///     resolve the SAME `selectedClipID`, `openEditorClip` requires
    ///     `isMIDI` and `openPitchEditorClip` requires `!isMIDI`. So no
    ///     one-at-a-time rule has to be written, tested or kept in sync. ⚠️ This
    ///     FUNCTION is still total over the impossible rows — a pure rule must
    ///     answer every input — and the roll wins them, because it is the older
    ///     surface and a tie-break nobody can reach should not be a new
    ///     behaviour. `EditorSurfaceRouterTests` sweeps them anyway, so if the
    ///     app ever does reach one, the answer is pinned rather than emergent.
    nonisolated public static func resolve(
        workspaceIsArrange: Bool,
        rollOpen: Bool,
        pitchEditorOpen: Bool,
        lastEngaged: EditorSurface
    ) -> ActiveEditorSurface {
        // ⭐ THE FIRST TWO GUARDS ARE NOT REPEATED HERE — THEY ARE CONSUMED
        // (m34-d). `openSurface` below applies exactly the workspace and
        // roll-open terms this function used to spell inline, in exactly this
        // order, and this switch adds only the engagement term on top. That is
        // the whole reason the two verdicts can coexist without the divergence
        // this file exists to prevent: there is ONE computation of "is a roll on
        // screen at all", and an edit to it moves both answers at once.
        //
        // ⚠️ BEHAVIOURALLY BYTE-IDENTICAL to the three-guard form it replaced —
        // `EditorSurfaceRouterTests.fullTruthTable` sweeps all eight rows and
        // asserts BOTH the surface and the reason, so a mapping slip here is a
        // red row, not a silent re-route.
        let open = openSurface(workspaceIsArrange: workspaceIsArrange, rollOpen: rollOpen,
                               pitchEditorOpen: pitchEditorOpen)
        switch open.reason {
        case .notArrangeWorkspace: return ActiveEditorSurface(.arrange, .notArrangeWorkspace)
        case .noRollOpen: return ActiveEditorSurface(.arrange, .noRollOpen)
        case .rollOpen:
            return lastEngaged == .pianoRoll
                ? ActiveEditorSurface(.pianoRoll, .engagedRoll)
                : ActiveEditorSurface(.arrange, .engagedArrange)
        case .pitchEditorOpen:
            // ⚠️ THE LATCH IS COMPARED AGAINST THE PANE THAT IS ACTUALLY OPEN,
            // never merely "is it non-arrange". A latch left on `.pianoRoll` by
            // an earlier MIDI clip must not hand ⌘+ to a roll that is not on
            // screen — the same failure the workspace term exists to prevent,
            // one surface over.
            return lastEngaged == .pitchEditor
                ? ActiveEditorSurface(.pitchEditor, .engagedPitchEditor)
                : ActiveEditorSurface(.arrange, .engagedArrange)
        }
    }

    /// Which editing surface is **OPEN** — mounted and available to act on —
    /// without asking whether the user has engaged it yet (m34-d).
    ///
    /// ⭐ **THE USER'S RULING, VERBATIM (2026-08-30): *"Make it work whenever the
    /// editor is open."*** They were shown the engagement behaviour — ⌘A doing
    /// nothing until you click inside the roll you are already looking at — and
    /// chose OPEN over ENGAGED for that key. This function is that choice,
    /// isolated to the one consumer that was ruled on.
    ///
    /// ⚠️ **NOT A REPLACEMENT FOR `resolve`, AND MOST CALLERS STILL WANT THAT
    /// ONE.** Reach for this only when the question is genuinely "is the surface
    /// in front of the user", and the act is one they cannot mistake for an act
    /// on the other surface. ⌘A qualifies on both counts: it has no other meaning
    /// anywhere in this app (`SelectAllMenuPolicy` deliberately never invented an
    /// arrange-wide select-all), so acting immediately steals from nothing. ⌘+
    /// does NOT qualify — both surfaces zoom, so "open" would have it zoom the
    /// one the user is not working in. ⌫ does not qualify either: it is
    /// destructive AND both surfaces claim it, which is why `DeleteMenuPolicy`
    /// routes on a third term again (`pianoRollWouldConsumeKey`).
    ///
    /// - Parameters:
    ///   - workspaceIsArrange: is the ARRANGE workspace live (as opposed to the
    ///     Mix console)?
    ///
    ///     ⚠️ **CARRIED FOR EXACTLY `resolve`'S REASON AND IT IS STILL THE
    ///     EASIEST THING TO DROP.** `openEditorClip` carries no workspace term,
    ///     so in the **Mix console** a MIDI clip stays selected while no
    ///     `PianoRollView` is mounted at all. Without this term ⌘A would select
    ///     notes in a roll the user cannot see — worse here than for zoom,
    ///     because the roll is not even on screen to show what happened.
    ///   - rollOpen: is a MIDI clip open in the piano roll (`openEditorClip !=
    ///     nil` — the tree's ONE rule for "the roll is on screen")?
    ///   - pitchEditorOpen: is an AUDIO clip open in the pitch editor
    ///     (`openPitchEditorClip != nil`)? Applied AFTER `rollOpen`: the two are
    ///     mutually exclusive in the app (see `resolve`), so the order is a
    ///     formality — but fixing it is what makes the truth table TOTAL rather
    ///     than leaving one cell to whichever guard happened to be written first.
    nonisolated public static func openSurface(
        workspaceIsArrange: Bool,
        rollOpen: Bool,
        pitchEditorOpen: Bool
    ) -> OpenEditorSurface {
        guard workspaceIsArrange else { return OpenEditorSurface(.arrange, .notArrangeWorkspace) }
        if rollOpen { return OpenEditorSurface(.pianoRoll, .rollOpen) }
        if pitchEditorOpen { return OpenEditorSurface(.pitchEditor, .pitchEditorOpen) }
        return OpenEditorSurface(.arrange, .noRollOpen)
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
