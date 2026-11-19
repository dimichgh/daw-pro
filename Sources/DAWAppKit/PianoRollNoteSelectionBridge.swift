import CoreGraphics
import DAWCore
import Foundation

/// The ONE home for the question "would the PIANO ROLL have consumed this
/// keystroke?", plus the debug-tier seam that lets a gate put the roll into the
/// state where it would.
///
/// WHY THIS EXISTS (m23-x, second pass). The arrange's arrow-key nudge must not
/// fire while the user is editing notes — press ← meaning "nudge this note" and
/// the whole CLIP sliding a bar underneath the open editor is the worst kind of
/// surprise. The obvious guard, `AppModel.pianoRollEditorFocused`, was written,
/// shipped to a staging binary, and MEASURED TO BE WRONG: `PianoRollView` does
/// `.onAppear { isFocused = true }` and `AppModel.openEditorClip` is non-nil for
/// ANY single selected MIDI clip, so that flag is already true in the perfectly
/// ordinary state "user clicked one MIDI clip in the arrange". Guarding on it
/// alone did not close a leak, it DELETED the feature's primary case — measured
/// on staging: one MIDI clip selected, → pressed, `refusedBy: piano-roll-focused`
/// and the clip did not move (0 → 0), with 9 of 46 gate assertions red and every
/// one of them a CONTROL half ("with the guard inactive the same call nudges").
///
/// THE RULE THIS ENCODES IS THE APP'S OWN, NOT A NEW ONE. `PianoRollView`'s
/// DELETE handler already reads:
///
///     .onKeyPress(.delete) {
///         guard !model.selection.isEmpty else { return .ignored }
///
/// — the roll consumes the key only when it HAS A NOTE SELECTION, and otherwise
/// lets it fall through so the arrange acts on the clip. (With the roll open and
/// no notes selected, DELETE deletes the whole clip today; that is shipped,
/// accepted behaviour.) So the faithful mirror of DELETE is not "refuse while
/// the roll is focused" but "refuse when the roll would have consumed it": the
/// editor is on screen AND holds a note selection. That fixes exactly the
/// reported surprise and leaves single-clip nudge alive.
///
/// AND FOCUS IS NOT A TERM IN THE SHIPPED PREDICATE AT ALL — a second
/// measurement, after the obvious repair. Keeping `pianoRollEditorFocused` as an
/// EXTRA term (focus AND notes) looks conservative and is in fact worse than
/// useless: the flag ALTERNATES DETERMINISTICALLY on clip switches. Twelve
/// consecutive select-a-MIDI-clip cycles reported
/// `true,false,true,false,…` — exactly 6 true and 6 false, with `editorClipId`
/// non-null on all twelve, and the false readings persisted through a further
/// 1.4 s (they latch; they are not late reports). `.onAppear { isFocused = true }`
/// on the incoming instance and `.onDisappear { onFocusChange(false) }` on the
/// outgoing one race on every `.id(clip.id)` rebuild, and the loser is whichever
/// SwiftUI runs second. A guard carrying that term would let the clip slide
/// underneath the editor on every OTHER clip selection — an intermittent version
/// of the very bug being fixed, which is harder to report and harder to trust
/// than a consistent one. `AppModel.openEditorClip` (derived from
/// `selectedClipID` + a store lookup, no focus anywhere) is the deterministic
/// way to ask "is the roll on screen", so the guard asks that instead.
///
/// The flag is still fine for what m21-c uses it for — routing ⌘+/⌘−/⌘0 to
/// whichever zoom the user most recently engaged, where being wrong every other
/// clip switch is a mild annoyance the user corrects with one more click. It is
/// not fine for silently moving the user's music. Same flag, different stakes.
///
/// WHY A BRIDGE OBJECT rather than a bare `Bool` on `AppModel`: the flag has to
/// be REPORTED OUT of a view whose `PianoRollModel` is `@State private` (so
/// nothing outside can read it), and the staging seam has to reach INTO that
/// same private model. Both directions, one subject, one file — the
/// `FollowPlayheadModel.externalScrollNonce` pattern this copies verbatim in
/// shape (observed nonce in, observed state out).
@MainActor
@Observable
public final class PianoRollNoteSelectionBridge {

    /// REPORTED BY THE ROLL. True while the open editor has at least one note
    /// selected — i.e. while the roll's own `.onKeyPress` handlers would claim a
    /// keystroke rather than let it fall through to the arrange.
    ///
    /// Reported from `.onChange(of:initial:)`, never from `body` (a write during
    /// `body` is the thing `onBarOpsStyle` gets away with only because nothing
    /// observes it; this one gates a keyboard path and must be observable).
    public private(set) var hasSelection = false

    /// STAGED FOR THE ROLL by `debug.arrangeSelection {act:"pianoRollNotes"}`.
    /// The view watches the nonce, so re-staging the same intent still applies
    /// (the `externalScrollNonce` reason: a gate must be able to ask twice).
    public private(set) var stageNonce = 0
    /// What the staged event asks for: select every note in the draft, or none.
    @ObservationIgnored public private(set) var stagedSelectAll = false

    /// ASKED OF THE ROLL by Edit ▸ Delete (m23-cf): delete the notes you have
    /// selected. The view watches the nonce, for `stageNonce`'s reason — the menu
    /// must be able to ask twice, and two deletes in a row are two distinct
    /// requests carrying identical payloads.
    ///
    /// A SECOND NONCE RATHER THAN A SECOND MEANING ON `stageNonce`, deliberately:
    /// that one carries "select all / select none" and its `stagedSelectAll`
    /// payload, and folding a destructive verb into it would make one number mean
    /// two things — the exact confusion `dropForWidenedArrangeSelection` was given
    /// its own name to avoid, only with the user's notes at stake.
    public private(set) var deleteNonce = 0

    /// ASKED OF THE ROLL by the app's key monitor (m34-k): run your Escape path
    /// — the roll's own mount body, the I4 ladder with the roll's LIVE facts —
    /// without a SwiftUI key delivery. `PitchEditorInteractionBridge.escapeNonce`
    /// is the pane's twin. It carries no rung: the roll re-asks the app's one
    /// ladder with its own gesture and selection, so the monitor's prediction
    /// can never apply a rung the roll disagrees with.
    ///
    /// A THIRD NONCE, for `deleteNonce`'s reason: one number, one meaning.
    public private(set) var escapeNonce = 0

    public init() {}

    /// The roll's report. Idempotent — the view calls it with `initial: true`.
    public func report(hasSelection: Bool) { self.hasSelection = hasSelection }

    /// EDIT ▸ DELETE ASKED THE ROLL TO DELETE ITS SELECTION (m23-cf).
    ///
    /// The only way anything outside can reach the roll's `@State private
    /// PianoRollModel`, which is why the request is a nonce rather than a direct
    /// call. It carries no payload: WHAT gets deleted is the roll's own
    /// selection, so the menu cannot name a target the roll disagrees with.
    ///
    /// INERT WITH NO ROLL MOUNTED, and inert with a mounted roll holding no
    /// selection — the view re-applies its own `guard !model.selection.isEmpty`,
    /// the same test its `.onKeyPress(.delete)` uses. The menu item is disabled in
    /// both states anyway (`DeleteMenuPolicy.editMenuItem` reads `hasSelection`);
    /// the view's guard is what makes a stale menu impossible to act on rather
    /// than merely unlikely.
    public func requestDelete() { deleteNonce += 1 }

    /// THE KEY MONITOR HANDED THE ROLL AN ESCAPE (m34-k). Inert with no roll
    /// mounted — the view watches without `initial:`, so a roll that appears
    /// later never replays it.
    public func requestEscape() { escapeNonce &+= 1 }

    /// Stage a note selection into whatever roll is on screen.
    public func stage(selectAll: Bool) {
        stagedSelectAll = selectAll
        stageNonce += 1
    }

    /// THE ROLL WENT AWAY. Called from `.onDisappear`, mirroring the existing
    /// `onFocusChange(false)` next to it, and load-bearing: a `hasSelection`
    /// left latched `true` after the editor closes would kill the arrow keys
    /// permanently, with nothing on screen to explain why — strictly worse than
    /// the bug this whole bridge exists to fix.
    public func clear() { hasSelection = false }

    /// THE ARRANGE SELECTION GREW PAST THE ROLL'S CLIP — drop the note claim
    /// (m23-ak). Driven by `AppModel.arrangeSelection`'s `didSet`, which asks
    /// `shouldDropNotes(from:to:)` below and calls this when the answer is yes.
    ///
    /// A DISTINCT VERB FROM `stage(selectAll: false)`, deliberately, even though
    /// the two bodies are the same two lines today. The callers MEAN different
    /// things: the seam means "a gate asked for the empty state", this means
    /// "your clip is no longer the whole selection, so give the keys back". One
    /// name for both would let a future change to staged-clear semantics — a
    /// gate-only affordance — silently rewrite what the user sees when they
    /// shift-click a second clip. Same nonce and same effect on purpose; the
    /// roll needs no new machinery to obey it (`PianoRollView`'s existing
    /// `.onChange(of: stageNonce)` already routes `stagedSelectAll == false` to
    /// `model.clearSelection()`).
    ///
    /// INERT WITH NO ROLL MOUNTED, and that is the intended behaviour: the
    /// view's `.onChange(of: stageNonce)` carries no `initial: true`, so a bump
    /// made while the editor is closed is NOT retroactively applied by the next
    /// roll that appears. It cannot be: a roll that appears later is a fresh
    /// `@State private PianoRollModel` with an empty selection anyway.
    ///
    /// IDEMPOTENT BY REPETITION, which the marquee needs. A rubber-band drag
    /// re-decides the whole selection on every pointer update, so this fires
    /// many times across one gesture; each extra call clears an already-empty
    /// set. Precisely (do not round this up to "no churn"): the REPORT path is
    /// quiet — `model.selection.isEmpty` does not change, so the roll's report
    /// `.onChange` never runs again — but the NONCE path is not silent. Every
    /// pointer update is its own 1 -> N crossing, so `.onChange(of: stageNonce)`
    /// does fire once per update and calls `clearSelection()` on an already
    /// empty set. That is idempotent, not free; it is cheap enough to accept and
    /// is the only reason the marquee needs no special case. VERIFIED ONLY BY
    /// READING the two `.onChange` bodies — the end-to-end marquee is an
    /// explicit SKIP in `scripts/gates/m23ak-note-selection-drop.mjs`.
    public func dropForWidenedArrangeSelection() {
        stagedSelectAll = false
        stageNonce += 1
    }

    /// THE ONE HOME FOR THE QUESTION "did the arrange selection just grow past
    /// the clip the roll is open on?" (m23-ak). Pure, `nonisolated`, and takes
    /// both endpoints, so it is decided in DAWAppKit where it can be tested
    /// headlessly rather than inside a `didSet` nothing can reach.
    ///
    /// WHAT IT FIXES. Select a MIDI clip, select notes in the roll, then
    /// shift-click two more clips in the arrange and press →: MEASURED, nothing
    /// happens (`refusedBy: piano-roll-note-edit`, starts unchanged), and DELETE
    /// removes the NOTES rather than the three clips. Both are correct under the
    /// m23-x predicate and wrong by intent — the user's evident target is the
    /// three-clip arrange selection. The trigger lives app-side and the roll
    /// EXECUTES, because the roll cannot see the arrange selection at all
    /// (`PianoRollModel` is `@State private`; this bridge is the only channel in
    /// either direction) and giving it that visibility would invert the layering
    /// the bridge exists to preserve.
    ///
    /// WHY CARDINALITY IS THE WHOLE TEST, with no term naming the focus. Under
    /// `ArrangeSelection`'s INV1 the focus is always a member of `ids`, so with
    /// the roll open (`focusID != nil`) `count > 1` is exactly `ids ⊋ {focusID}`
    /// — "there is now a selected clip that is not the one you are editing".
    /// Naming the focus would restate INV1 and could only disagree with it.
    ///
    /// WHY IT READS THE RESULTING STATE rather than the gesture: that covers all
    /// three growth paths — `toggle` (shift/⌘-click), `replace` (a marquee, and
    /// the track-header click that runs through `ArrangeTrackSelection`) and
    /// `formUnion` (an additive marquee) — with no gesture-specific term and
    /// nothing to add when a fourth path lands. `replace` is the one that would
    /// be missed by a "did ids gain a member" reading: a band can swap the whole
    /// set at once.
    ///
    /// WHY A TRANSITION AND NOT A STANDING CONDITION. The roadmap's word is
    /// "grows". `old.count <= 1` is what makes this fire on the crossing and not
    /// forever after, and the consequence is deliberate: if the user
    /// DELIBERATELY selects notes again while three clips are selected, their
    /// notes are KEPT and the nudge refuses again. At that point their intent is
    /// plainly the notes — they just asked for them, with the wide selection
    /// already on screen — and re-clearing would be the app arguing with them.
    /// `<=` rather than `==` so a 0 → 2 marquee (nothing selected, band sweeps
    /// two clips) is also a growth; the roll is not open at 0, so that case
    /// costs an inert nonce bump and keeps the rule stated in one place.
    ///
    /// NOT GUARDED ON "is a roll even open". The bridge call is inert without
    /// one (see `dropForWidenedArrangeSelection`), and this function deciding it
    /// would need `openEditorClip`, which is an `AppModel` + store lookup — i.e.
    /// exactly the dependency that would stop this being headless and pure.
    nonisolated public static func shouldDropNotes(from old: ArrangeSelection,
                                                   to new: ArrangeSelection) -> Bool {
        old.count <= 1 && new.count > 1
    }

    // MARK: - The RUBBER BAND seam (m23-ek-1)

    /// STAGED FOR THE ROLL by `debug.pianoRollMarquee`: one step of a
    /// synthesized grid gesture, run through the roll's own press/drag/release
    /// handlers.
    ///
    /// ⚠️ A THIRD NONCE, NOT A THIRD MEANING ON `stageNonce`, and this one is
    /// not merely stylistic housekeeping: the view's existing
    /// `.onChange(of: stageNonce)` routes `stagedSelectAll == false` straight to
    /// `model.clearSelection()`. Reusing it would wipe the selection on every
    /// single marquee step — the band would report an empty set for a gesture
    /// that had just selected forty notes.
    public private(set) var marqueeStageNonce = 0
    /// The step the staged gesture asks for. `@ObservationIgnored` for
    /// `stagedSelectAll`'s reason: the nonce is what observers watch, and a
    /// second observable property would fire a second update per request.
    @ObservationIgnored public private(set) var marqueeStage: PianoRollMarqueeStage?

    /// REPORTED BY THE ROLL — the band rect the grid is DRAWING, or nil when no
    /// band is in flight. Ground truth, never the seam's input: it is the very
    /// `@State` the overlay renders from, handed out after it is stored.
    ///
    /// ⚠️ `@ObservationIgnored`, and that is the load-bearing half of this whole
    /// seam. `DeleteMenuPolicy.swift:136-143` anticipated this feature and warned
    /// against the obvious implementation: `hasSelection` above publishes a BOOL
    /// reported on the empty ↔ non-empty TRANSITION only, because it gates a
    /// keyboard path (`AppModel.pianoRollWouldConsumeKey`). Making any of the
    /// marquee's per-pointer-tick state observable would invalidate the
    /// observation graph on every update of a band drag — a correctness
    /// regression for the keyboard gate, not merely a performance one. Nothing
    /// below is observed; it is read at SEAM time and nowhere else.
    @ObservationIgnored public private(set) var marqueeBand: CGRect?
    /// What the last reported band TOUCHED — distinct from the selection, which
    /// under an additive chord is `base ∪ hits`.
    @ObservationIgnored public private(set) var marqueeHits: Set<UUID> = []
    /// The grid's live scales, content and selection (see `PianoRollSurfaceState`).
    @ObservationIgnored public private(set) var surface: PianoRollSurfaceState = .empty
    /// Bumped on every MARQUEE report — the seam's proof that a staged step has
    /// been THROUGH the view (the m23-e echo-seam law). Deliberately NOT bumped
    /// by `reportSurface`, so a routine relayout can never satisfy a bounded
    /// wait that is standing on a staged step.
    @ObservationIgnored public private(set) var marqueeReportSeq = 0

    /// Whether the roll still has a grid gesture in flight — `activeDrag != .none`,
    /// reported up rather than inferred.
    ///
    /// ⚠️ THIS EXISTS TO MAKE AN UNBALANCED STAGED GESTURE FAIL LOUDLY. A staged
    /// `begin` arriving while a gesture is already open cannot start a press (the
    /// mouse cannot either), so the view drops it — and the seam would otherwise
    /// answer with a perfectly plausible echo while the NEXT `changed` computed
    /// its band from the PREVIOUS gesture's origin. That is a wrong answer rather
    /// than an error, the worst shape a diagnostic can take. `pianoRollMarquee`
    /// reads this and throws instead.
    @ObservationIgnored public private(set) var marqueeGestureInFlight = false

    /// The roll instance whose surface report is currently standing, or nil when
    /// no roll is mounted. See `clearSurface(from:)`.
    @ObservationIgnored private var surfaceReporter: UUID?

    /// Ask the visible roll to run one step of a grid gesture — the only way
    /// anything outside can drive the roll's pointer handling, since
    /// `PianoRollModel` is `@State private`. Inert with no roll mounted, like
    /// every other nonce here.
    public func stageMarquee(_ stage: PianoRollMarqueeStage) {
        marqueeStage = stage
        marqueeStageNonce += 1
    }

    /// THE GRID DREW THIS — its scales, its content and its selection. Called
    /// from the roll on first render and whenever any of it changes, so a BARE
    /// `debug.pianoRollMarquee {}` read can answer the ladder a fixture must be
    /// computed FROM even though no gesture has ever run.
    ///
    /// Does NOT bump `marqueeReportSeq` (see above).
    ///
    /// - Parameter token: identifies the reporting roll INSTANCE — see
    ///   `clearSurface(from:)`.
    public func reportSurface(token: UUID, _ state: PianoRollSurfaceState) {
        surfaceReporter = token
        surface = state
    }

    /// THE BAND MOVED (or was put away). Carries the surface state ALONGSIDE the
    /// band rather than leaving it to `reportSurface`'s `.onChange`, and that is
    /// not redundancy: `awaitPianoRollMarqueeApplied` stops the instant this
    /// bumps the sequence, which can happen BEFORE SwiftUI runs the body pass
    /// that would fire the surface report. A seam that answered with a
    /// pre-gesture selection would not merely fail a gate — a stale echo poisons
    /// every diagnosis made through it.
    public func reportMarquee(
        band: CGRect?, hits: Set<UUID>, surface: PianoRollSurfaceState, gestureInFlight: Bool
    ) {
        marqueeBand = band
        marqueeHits = hits
        self.surface = surface
        marqueeGestureInFlight = gestureInFlight
        marqueeReportSeq &+= 1
    }

    /// THE ROLL WENT AWAY — drop the surface echo with it, for `clear()`'s
    /// reason: a latched band or a latched ladder would let the seam answer with
    /// a grid nothing is drawing.
    ///
    /// ⚠️ THE TOKEN IS WHY A CLIP SWITCH DOES NOT BLANK A LIVE ROLL. The editor
    /// is rebuilt on `.id(clip.id)`, so switching clips tears down one roll and
    /// stands up another, and SwiftUI does not promise which runs first — this
    /// file's own header documents that race, MEASURED, one flag over. A
    /// teardown clears only while the LAST report was its own, so the incoming
    /// roll's report supersedes the outgoing roll's clear in either order.
    /// (`clear()` keeps its unguarded shape: its `hasSelection = false` is
    /// re-established by the incoming roll's `initial: true` report, which is
    /// exactly what makes the race benign THERE and not here.)
    public func clearSurface(from token: UUID) {
        guard surfaceReporter == token else { return }
        surfaceReporter = nil
        marqueeBand = nil
        marqueeHits = []
        surface = .empty
        // The roll that owned the gesture is GONE, so nothing can deliver its
        // release — leaving this latched would lock the seam out of every
        // subsequent `begin` for the lifetime of the app.
        marqueeGestureInFlight = false
        marqueeReportSeq &+= 1
    }

    // MARK: - The CLIPBOARD seam (m23-ek-3)

    /// ASKED OF THE ROLL by Edit ▸ Copy / Cut / Paste and by the roll's own
    /// context menu: run this clipboard operation on your notes.
    ///
    /// A FOURTH NONCE, and — like `marqueeStageNonce` — not merely stylistic
    /// housekeeping. `stageNonce` routes `stagedSelectAll == false` straight to
    /// `model.clearSelection()`, so reusing it would wipe the selection the copy
    /// was about to read. `deleteNonce` carries a destructive verb with no
    /// payload. This one carries a VERB and, for paste, a payload of notes, and
    /// folding three meanings into one number is exactly the confusion
    /// `dropForWidenedArrangeSelection` was given its own name to avoid.
    ///
    /// WHY THE ROLL AND NOT THE MENU DOES THE WORK. `PianoRollModel` is `@State
    /// private`, so nothing outside can read the selection or the draft — the
    /// same wall every other nonce here exists to cross. ⚠️ AND THE MENU MUST
    /// NOT READ `surface.selection` INSTEAD: that echo is published from the
    /// roll's `.onChange(of: surfaceState)`, i.e. one body pass BEHIND a
    /// selection change (this file's `marqueeReportSeq` note and
    /// `awaitPianoRollMarqueeApplied`'s second wait both record the lag,
    /// measured). Fine for a human clicking a menu; INTERMITTENT for a gate that
    /// copies immediately after a staged marquee. The roll owns `model.draft`
    /// and `model.selection` directly, so a copy resolved there has nothing to
    /// be stale.
    public private(set) var clipboardNonce = 0

    /// Which operation the staged request is. `@ObservationIgnored` for
    /// `stagedSelectAll`'s reason: the nonce is what observers watch, and a
    /// second observable property would fire a second update per request.
    @ObservationIgnored public private(set) var stagedClipboardVerb: ClipboardVerb = .copy

    /// Ask the roll to COPY its selected notes out.
    public func requestCopy() { requestClipboard(.copy) }

    /// Ask the roll to CUT its selected notes.
    ///
    /// ⚠️ THE ROLL WRITES THE CLIPBOARD ONLY AFTER THE STORE ACCEPTS THE
    /// REMOVAL — see `PianoRollView`'s handler. A clipboard left loaded while
    /// nothing was actually cut is a lie about what happened.
    public func requestCut() { requestClipboard(.cut) }

    /// Ask the roll to PASTE the clipboard's notes at its playhead.
    ///
    /// ⚠️ NO PAYLOAD RIDES THIS NONCE, DELIBERATELY. The notes reach the roll as
    /// an ordinary view property fed from `AppModel.clipboard`, which is
    /// `@Observable` — so the roll's own context-menu Paste can be titled and
    /// enabled from the LIVE clipboard at all times. Staging the payload here
    /// instead would have made that entry readable only AFTER an Edit ▸ Paste had
    /// already run, i.e. permanently disabled on the route that needs it most.
    public func requestPaste() { requestClipboard(.paste) }

    private func requestClipboard(_ verb: ClipboardVerb) {
        stagedClipboardVerb = verb
        clipboardNonce += 1
    }

    // MARK: - The SELECT ALL seam (m25-s)

    /// ASKED OF THE ROLL by ⌘A / Edit ▸ Select All: select every note you are
    /// drawing.
    ///
    /// ⚠️⚠️ **A FIFTH NONCE, AND IT IS NOT `stageNonce` — THIS IS THE WHOLE
    /// DESIGN OF m25-s, NOT HOUSEKEEPING.** `stage(selectAll: true)` above
    /// already selects every note in the open roll, and routing the user's
    /// keystroke through it would have been a two-line change. It is refused for
    /// two independent reasons:
    ///
    ///   • `stageNonce` IS A TEST AFFORDANCE. It exists so `debug.arrangeSelection
    ///     {act:"pianoRollNotes"}` can reach a `@State private PianoRollModel`
    ///     that nothing outside can otherwise touch. A USER KEYSTROKE MUST NOT
    ///     DEPEND ON A DEBUG SEAM: the day that seam is gated, renamed or
    ///     compiled out, ⌘A would go with it, and nothing would say so.
    ///   • IT ALREADY MEANS THREE THINGS. Its `stagedSelectAll == false` branch
    ///     routes straight to `model.clearSelection()`, AND it is bumped by the
    ///     PRODUCTION path `dropForWidenedArrangeSelection()` (m23-ak) meaning
    ///     "your clip is no longer the whole selection". A fourth meaning on one
    ///     number is exactly the confusion `deleteNonce`, `marqueeStageNonce` and
    ///     `clipboardNonce` were each given their own name to avoid — with the
    ///     added twist that a ⌘A and a gate's staged CLEAR would be
    ///     indistinguishable at the receiving `.onChange`.
    ///
    /// ⭐ **THE VERB IS SHARED, THE MECHANISM IS NOT.** Both this nonce and
    /// `stageNonce`'s select-all branch land on `PianoRollModel.selectAllNotes()`
    /// — extracted at m25-s from the inline expression that used to live in the
    /// view — so the seam and the keystroke can never select different things.
    /// Sharing the RULE while separating the ROUTE is the m23-cf shape.
    ///
    /// CARRIES NO PAYLOAD, like `deleteNonce`: WHAT gets selected is the roll's
    /// own draft, so the menu cannot name a target the roll disagrees with.
    ///
    /// INERT WITH NO ROLL MOUNTED (`.onChange` without `initial: true` — every
    /// other nonce's behaviour), and that is correct rather than merely
    /// tolerable: `SelectAllMenuPolicy` refuses unless the roll is OPEN, which
    /// IS "a roll is mounted" — that is what the term means.
    ///
    /// ⭐ **RE-CHECKED AT m34-d AND IT GOT STRONGER, NOT WEAKER.** The sentence
    /// above used to read "unless the roll is the ACTIVE surface, which already
    /// implies a mounted roll" — a correct but INDIRECT argument that leaned on
    /// engagement implying mount. The user's ruling (*"Make it work whenever the
    /// editor is open."*) replaced that first guard with
    /// `EditorSurfaceRouter.openSurface`, so the policy's condition and the
    /// roll's mount condition are now THE SAME FACT rather than one implying the
    /// other. The widening therefore cannot have opened a window in which a
    /// request is dropped: every state that is newly LIVE is a state in which a
    /// `PianoRollView` is on screen.
    ///
    /// ⚠️ **"MOUNTED" IS NOT THE SAME INSTANT AS "OBSERVING", AND THAT GAP IS
    /// REAL — MEASURED at m34-d.** `.onChange` fires only for changes that happen
    /// while the view is subscribed, so a request that arrives during a remount
    /// (e.g. straight after leaving the Mix console) is LOST, not queued. No user
    /// can hit that window by hand — it is sub-frame — but a GATE can, and one
    /// did: `m34d-select-all-editor-open.mjs`'s K8a leg exists to arm the fixture
    /// past it, because `{act:"pianoRollNotes", select:false}` succeeds trivially
    /// against a roll that is not observing and would hide it.
    public private(set) var selectAllNonce = 0

    /// Ask the roll to SELECT ALL of its notes.
    public func requestSelectAll() { selectAllNonce += 1 }

    // MARK: - The WORDS lane (p2-sing-pr-words, design 2026-10-12 §2.5)

    /// REPORTED BY THE ROLL. True while its Words lane is on screen WITH WORDS TO TYPE ON — shown, and not in its
    /// empty state (no stored words: the field cannot open there, and a Return swallowed for nothing is a key that
    /// did nothing). The second fact the key monitor's Return route reads (`WordFieldKeyMonitorRouting.route`), beside
    /// `hasSelection`; reported from `.onChange(of:initial:)`, never from `body`, for `hasSelection`'s reason.
    ///
    /// ⚠️ `clear()` DOES NOT RESET IT, ON PURPOSE. On a clip switch the outgoing roll's `.onDisappear` and the incoming
    /// roll's `initial: true` report race in either order (this file's header, MEASURED one flag over). A reset there
    /// that ran SECOND would latch `false` under a lane that IS shown — and the lane's visibility does not change
    /// again, so Return would stay dead until the user toggled the lane. Latched `true` is harmless by construction:
    /// the route also needs `hasSelection` (which `clear()` does reset and only a live roll sets) and an OPEN roll.
    public private(set) var wordsShown = false

    /// ASKED OF THE ROLL by the app's key monitor: Return was pressed with notes selected and the lane shown — open
    /// the word field on your earliest selected melody note (`PianoRollWordsModel.openField(selection:)`, with the
    /// roll's LIVE selection). A SIXTH NONCE, for `deleteNonce`'s reason: one number, one meaning. Carries no payload:
    /// WHICH note is the roll's own selection's answer. Inert with no roll mounted (`.onChange` without `initial:`).
    public private(set) var wordFieldNonce = 0

    /// The roll's report. Idempotent — the view calls it with `initial: true`.
    public func reportWordsShown(_ shown: Bool) { wordsShown = shown }

    /// THE KEY MONITOR HANDED THE ROLL A RETURN (p2-sing-pr-words).
    public func requestWordField() { wordFieldNonce &+= 1 }
}
