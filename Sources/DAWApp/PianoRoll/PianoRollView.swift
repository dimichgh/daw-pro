import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Bottom piano-roll editor panel for a MIDI clip. Thin over `PianoRollModel`:
/// all geometry + edits live there, this draws the grid/notes (Canvas) and
/// routes gestures. Every edit mutates the model draft; the draft is submitted
/// through `onCommit` on gesture END only (never per tick).
///
/// The transport playhead + scrub (beta m10-e) are RENDERINGS of existing state:
/// `positionBeats` is the SAME source the arrange timeline consumes (no second
/// ticker), mapped clip-local by the headless `PianoRollPlayhead`; the cyan line
/// shows only while the transport is inside the edited clip — off-clip the SAME
/// bands (the note grid, plus the velocity lane in Pro; never the controller
/// strip, which carries neither) show the `OffClipEdgeCue` instead (m23-c1) —
/// and `onSeek` is the
/// app's store seek (the existing `transport.seek` path, NOT the WebSocket).
struct PianoRollView: View {
    /// The clip being edited (value input — previewable without the store).
    var clip: Clip
    var beatsPerBar: Int
    /// Live transport position in PROJECT beats (the arrange timeline's source),
    /// mapped clip-local for the playhead. A plain value input so a preview can
    /// stage the line at any position.
    var positionBeats: Double
    /// Whether the transport is rolling (m23-c2). Follow keeps the playhead in
    /// frame DURING PLAYBACK only, so this gates it — a seek must not scroll the
    /// editor out from under an edit.
    var isPlaying: Bool
    /// The shared per-panel density store (docs/DESIGN-LANGUAGE.md "Panels"). The
    /// piano roll reads/sets its Simple/Pro mode under `panelID`, so the mode is
    /// now sticky across close/reopen and relaunch. A plain value input — a
    /// preview can pass a `PanelDensityStore()` with an in-memory backing.
    var densityStore: PanelDensityStore
    /// **The APP-LEVEL snap currently in force (m25-ab)** — `AppModel.effectiveClipSnap`,
    /// i.e. the arrange toolbar's `SNAP:` chip after its own density lock.
    ///
    /// The roll keeps its own DIVISION (`snap`); this input carries exactly one
    /// thing across the boundary — whether the user has turned snapping OFF app-wide
    /// — and `SnapResolution.effective` is the only thing allowed to combine the
    /// two. Before it existed the toolbar chip and the roll's chip rendered the same
    /// string and meant different things, and turning snap off left the note editor's
    /// playhead rounding to whole beats.
    ///
    /// ⚠️ Defaults to `.bar` (any non-`.off` value would do) so a call site that
    /// forgets it gets SNAPPING, not silent free placement — the fail-safe
    /// direction. Previews stay one-liner-simple.
    var appSnap: ClipSnap = .bar
    /// The shared layout store (m21-c): owns the persisted `pianoRollPPB` zoom
    /// slot every band rescales from. A plain value input — a preview can pass
    /// a `PanelLayoutStore()` with an in-memory backing.
    var layout: PanelLayoutStore
    /// The ROLL's follow runtime (m23-c2) — its suspension state and the offset it
    /// last asked for. Held by the app (not this view's `@State`) so it survives a
    /// clip switch and so `debug.followPlayhead` can echo the roll's ground truth.
    /// The ON/OFF flag itself is `layout.followPlayhead`: ONE value for both
    /// following surfaces.
    var follow: FollowPlayheadModel
    /// Submits the whole note array (wired to `ProjectStore.setClipNotes`).
    ///
    /// `extendToCover` (m25-a) names the notes THIS gesture placed or moved, and
    /// is the auto-extend request: if one of them lands past the clip's end the
    /// store grows the clip to cover it, in the SAME undo step as the note
    /// write. Empty (the usual case) = the pre-m25-a behaviour exactly. The set
    /// travels as a second ARGUMENT rather than as a second closure precisely
    /// because it must not become a second store call — two calls would be two
    /// undo entries.
    ///
    /// **RETURNS the auto-extend refusal to show, or nil (m25-a-2)** — the
    /// `onCutNotes -> Bool` / `onCommitControllerLane -> Clip?` precedent: the
    /// closure hands the store's result back so the view can decide what to
    /// draw. It is a RETURN rather than a second `onAutoExtendRefused` closure
    /// because the refusal belongs to THIS call: a separate channel could be
    /// read a beat late, and one funnel returning one answer cannot desync.
    ///
    /// ⚠️ **NIL IS OVERWHELMINGLY THE NORMAL ANSWER, INCLUDING WHEN NOTHING
    /// GREW.** The store distinguishes "the notes already fit" (the ordinary
    /// case, on every edit inside the clip, and on every DELETE / velocity-lane
    /// commit that passes an empty `extendToCover`) from the three real
    /// refusals. This view must never re-derive that distinction — it renders
    /// the words it is handed and nothing else.
    var onCommit: (_ notes: [MIDINote], _ extendToCover: Set<UUID>) -> String?
    /// Seeks the transport to a PROJECT beat (wired to `ProjectStore.seek`) — the
    /// scrub's only side effect. Kept a closure so the view stays store-free and
    /// previewable (the `onCommit` precedent).
    var onSeek: (Double) -> Void
    /// Excises a CLIP-LOCAL beat range and closes the gap (wired to
    /// `ProjectStore.deleteTimeRange`); returns the updated clip so the view can
    /// reseed its edit model, or nil if the store rejected it. Store-free closure
    /// (the `onCommit`/`onSeek` precedent) so the view stays previewable (m10-h).
    var onDeleteTimeRange: (_ startBeat: Double, _ lengthBeats: Double) -> Clip?
    /// Inserts CLIP-LOCAL silence, pushing later notes right (wired to
    /// `ProjectStore.insertTimeRange`); returns the updated clip or nil (m10-h).
    var onInsertTimeRange: (_ atBeat: Double, _ lengthBeats: Double) -> Clip?
    /// Opens the Quantize & Groove panel for this clip (m11-a) — the panel owns its
    /// own density, so this affordance shows in both piano-roll modes (tightening
    /// timing is a beginner action; the panel's Simple mode is grid + strength).
    var onOpenQuantize: () -> Void
    /// Opens the Humanize panel for this clip (m25-c) — the QUANTIZE chip's
    /// sibling, and its inverse: quantize pulls onsets toward the grid, humanize
    /// nudges them (and velocities) off it. Shown in BOTH densities for the same
    /// reason quantize is: "make this sound less robotic" is a beginner action.
    /// Store-free closure (the `onOpenQuantize` precedent) so the view stays
    /// previewable.
    var onOpenHumanize: () -> Void = {}
    /// Commits the visible controller lane (m16-b4) through
    /// `ProjectStore.setControllerLane` — the SAME store call the
    /// `clip.setControllerLane` wire verb uses — and returns the updated clip so
    /// the strip can reseed its edit model (the bar-ops reseed idiom). Store-free
    /// closure (the `onCommit` precedent) so the view stays previewable.
    var onCommitControllerLane: (_ type: MIDIControllerType, _ points: [MIDIControllerPoint]) -> Clip?
    /// m23-ek-3 — puts these notes on the app's `EditClipboard`. COPY HAS NO
    /// DOMAIN EFFECT, which is why it returns nothing and why it is not a wire
    /// verb: it mutates the project not at all.
    var onCopyNotes: ([MIDINote]) -> Void
    /// m23-ek-3 — CUT: removes the selected notes and, ONLY IF THE STORE
    /// ACCEPTED THE REMOVAL, puts them on the clipboard. Returns whether it did.
    ///
    /// ⚠️ THE RETURN VALUE IS WHY THIS IS NOT `onCopyNotes` + `deleteSelection()`
    /// AT THE CALL SITE. `setClipNotes` can refuse (a take-comp member), and a
    /// cut that left the clipboard loaded while nothing was removed is a lie
    /// about what happened. The view applies its own draft change only on
    /// `true`, so the roll and the store cannot end up disagreeing either. The
    /// `onCommitControllerLane` precedent — a closure that hands the store's
    /// result back so the view can decide.
    var onCutNotes: (_ copied: [MIDINote], _ remaining: [MIDINote]) -> Bool
    /// m23-ek-3 — submits the whole note array through the UNCOALESCED
    /// `ProjectStore.pasteNotes`, NOT through `onCommit`/`setClipNotes`.
    ///
    /// ⚠️⚠️ THE DISTINCTION IS THE ENTIRE POINT AND IS NOT COSMETIC.
    /// `setClipNotes` journals under `key: "clip.notes:<id>"` and the undo
    /// journal folds same-key edits inside 800 ms — so a paste routed through
    /// `onCommit` within 800 ms of a note drag on this clip would FOLD INTO IT,
    /// and one ⌘Z would undo both. `pasteNotes` passes no key, so it never
    /// merges in either direction.
    ///
    /// **`extendToCover` (m25-f-2) — THE IDS THIS PASTE PLACED, not the
    /// selection.** A paste landing past the clip's end grows the clip to cover
    /// it, inside the SAME undo step as the note write. The two arguments look
    /// redundant (the ids are all in the array) and are not: the store must be
    /// told WHICH notes this gesture placed, because the array is the whole
    /// draft and may already hold legal-but-latent notes far past the end that
    /// must NOT move the clip's edge (m18-f / m25-a). They coincide with
    /// `model.selection` today only because the paste selects what it pasted —
    /// the invariant being encoded is "what this gesture placed", so the call
    /// site passes an explicit set rather than reading the selection back.
    ///
    /// **RETURNS the auto-extend refusal to show, or nil (m25-a-2)** — same
    /// contract as `onCommit`, wired to the SAME store message helper. Wiring
    /// only the note-edit funnel would leave a refused paste silent, which is
    /// half the defect.
    var onPasteNotes: (_ notes: [MIDINote], _ extendToCover: Set<UUID>) -> String?
    /// m23-ek-3 — the notes currently on `AppModel.clipboard`, clip-local and
    /// UNTRANSLATED, or empty when the clipboard holds clips or nothing.
    ///
    /// A PLAIN VALUE RATHER THAN A BRIDGE NONCE PAYLOAD, and that is what makes
    /// the roll's own context-menu Paste honest: `EditClipboard` is
    /// `@Observable`, so this re-flows the instant a copy lands anywhere in the
    /// app, and the entry can be titled ("Paste 12 Notes") and enabled from the
    /// LIVE clipboard. Staging it on the request nonce instead would have left
    /// that entry disabled until an Edit ▸ Paste had already run.
    var clipboardNotes: [MIDINote]
    var onClose: () -> Void
    /// ESCAPE reaching the roll (m25-b-1) — asks the APP whether the keystroke
    /// leaves the MAXIMIZED editor mode, and reports whether it was consumed.
    /// A closure, not a `layout` read, for the reason the DELETE route is one:
    /// the decision needs app-level facts this view has no business knowing (is a
    /// modal up, is a rename field live), and both of Escape's mounts must reach
    /// the SAME decision. Defaulted so previews stay one-liner-simple; a preview
    /// that never maximizes never needs it.
    var onEscape: () -> Bool
    /// Sounds EXACTLY these pitches on the clip's track right now — SET
    /// semantics, so an empty array is "stop" (m23-d). Called on every gesture
    /// tick; the controller below diffs, so this view neither throttles nor
    /// decides when to retrigger. `velocity` is the anchor note's own velocity,
    /// so a drag sounds as the note will actually sound. Store-free closure (the
    /// `onCommit`/`onSeek` precedent) — the view stays previewable, and holds NO
    /// audition policy: the voice cap, the retrigger rule, the heartbeat and the
    /// defeat switch all live outside it.
    var onAudition: (_ pitches: [Int], _ velocity: Int) -> Void

    /// Reports the editor's key-focus state (m21-c) so the app can route the
    /// View-menu ⌘+/⌘−/⌘0 to THIS editor's zoom while it is focused (menu key
    /// equivalents fire before any focused view sees the key, so the routing
    /// must happen app-side). Defaulted so previews stay one-liner-simple.
    var onFocusChange: (Bool) -> Void

    /// Reports that the user just ACTED INSIDE THIS EDITOR (m23-al) — a gesture,
    /// not a focus state. The app turns it into "the roll is the surface the user
    /// is working in", which is what ⌘+/⌘−/⌘0 route on
    /// (`EditorSurfaceRouter.resolve`). Defaulted to a no-op so previews and any
    /// future call site stay one-liner-simple.
    ///
    /// ⚠️ CALLED FROM EIGHT ENUMERATED FUNNELS (R1–R8, all marked `m23-al Rn`),
    /// NOT from a single root `.simultaneousGesture` on `body`. That draft was
    /// rejected on purpose: nothing in this tree can PROVE such a gesture fires on
    /// a click inside the grid's descendant `ScrollView` (m23-bw), and its failure
    /// mode is silent and TOTAL — the roll could never be engaged, ⌘+ would never
    /// reach it, and every gate leg except one would still pass. An enumerated
    /// funnel someone forgets costs one gesture; that would cost the feature.
    /// `EditorSurfaceOwnershipSiteTests` pins that all eight still exist and that
    /// the gesture-attachment count under `Sources/DAWApp/PianoRoll/` has not
    /// grown behind their backs.
    var onEngage: () -> Void

    /// ⭐ THE DELETE KEY, ROUTED (m23-cf, second pass). Returns true when SOME
    /// surface owned the keystroke — which is what this view answers `.handled`
    /// from. It is NOT "notes were deleted", and the difference is the point: see
    /// `AppModel.handleDeleteKey`.
    ///
    /// ⚠️ THIS VIEW NO LONGER DECIDES WHETHER IT OWNS DELETE. It used to
    /// (`guard !model.selection.isEmpty` inline), and that was one of THREE
    /// focus-gated handlers each answering the question its own way while SwiftUI
    /// picked between them non-deterministically — the reported bug. The decision
    /// is `DeleteMenuPolicy.keyPress`; when it names this roll, the app bumps
    /// `noteSelection.deleteNonce` and the `.onChange` handler below does the
    /// work, i.e. the roll still executes its own delete through its own
    /// `@State private` model. Do NOT re-add a local rule here "for safety": two
    /// computations of one rule is the m23-x → m23-al defect this closed.
    ///
    /// Defaulted to a refusal so previews stay one-liner-simple. `false` means
    /// `.ignored`, so an unwired preview propagates the key rather than eating it.
    var onDeleteKey: () -> Bool = { false }

    /// THE STEP SEQUENCER's session state + staging seam (m23-cq-1): which
    /// editor this pane shows, the picked step size, the staged toggle coming
    /// in, and the drawn grid going out. Held by the app (not this view's
    /// `@State`) so the mode survives a clip switch — the workflow this surface
    /// exists for is programming several drum clips in a row — and so
    /// `debug.stepSequencer` can drive the SAME path the chips drive.
    var stepSequencer: StepSequencerBridge

    /// Whether this clip's track addresses a GM drum kit
    /// (`SMFProjectExporter.isDrumKit` — the app's ONE predicate, resolved by
    /// the caller because this view is store-free by design). Decides the
    /// sequencer's lane set (named percussion rows vs. a pitch window) and,
    /// until the user picks a mode, which editor the pane opens in.
    var isDrumKit: Bool

    /// The NOTE-SELECTION bridge (m23-x, second pass) — reports out whether this
    /// editor currently has notes selected, which is the app's own test for
    /// "would the roll have consumed this key?" (see its `.onKeyPress(.delete)`
    /// below), and carries the debug seam's staged selection back in. Defaulted
    /// so previews and existing call sites stay one-liner-simple.
    var noteSelection: PianoRollNoteSelectionBridge

    /// Publishes the bar-ops readout's DRAWN text and ink (m23-t) so
    /// `debug.pianoRollBarOps` can report what this header actually put on
    /// screen. Called from inside the `Text`/`.foregroundStyle` arguments — see
    /// `reportedBarOpsText`/`reportedBarOpsInk`. Defaulted to a no-op so
    /// previews and any future call site stay one-liner-simple.
    ///
    /// The ink crosses as a `Color`, NOT as a resolved hex string: this cluster
    /// is fed `positionBeats`, so it re-evaluates ~29 times a second while the
    /// transport runs (MEASURED, not assumed — `debug.pianoRollBarOps.ticks`
    /// counted 118 REPORTS in 2.007 s, and there are TWO reports per body: the
    /// string and the ink),
    /// and resolving through `NSColor` on the way out would put a per-frame
    /// allocation in drawing code. The ledger resolves once per CHANGE instead.
    var onBarOpsStyle: (_ role: String, _ text: String?, _ ink: Color?) -> Void = { _, _, _ in }

    @State private var model: PianoRollModel
    /// Edit model for the Pro controller strip (m16-b4), seeded from the clip's
    /// lanes. Recreated with the view on a clip switch (`.id(clip.id)`).
    @State private var controllerModel: ControllerStripModel
    /// The roll's OWN grid division — 16ths for notes while the arrange sits on
    /// bars is a legitimate independence and this is where it lives.
    ///
    /// ⚠️ **IT IS NOT THE ANSWER TO "does this surface snap" — read `effectiveSnap`,
    /// never this (m25-ab).** `appSnap` can veto it, and for four milestones this
    /// `@State` WAS the whole answer, which is precisely the bug the user reported:
    /// the toolbar's `SNAP:` chip and this one rendered the identical string and
    /// were unrelated.
    ///
    /// ⭐ **KNOWN AND ACCEPTED: `@State private` means this resets to `.beat` on a
    /// clip switch** — the view is mounted `.id(clip.id)` (see
    /// `PanelLayoutStore.pianoRollMinimapKey`'s doc for the same hazard, solved
    /// there by persisting). Persisting a 9-case string enum needs a stable code
    /// map through the `Double`-only `PanelLayoutBacking`, which is a bigger change
    /// than this fix, so it is deliberately left. It does NOT weaken the fix: the
    /// user's OFF arrives through `appSnap`, which is app-held and survives the
    /// rebuild.
    @State private var snap: SnapResolution = .beat
    @State private var activeDrag: ActiveDrag = .none
    @State private var didMove = false
    /// m25-r — the last REAL pointer event of a live content drag, in the form
    /// the held-at-edge repeat needs (viewport-local x, so a scroll cannot make
    /// it stale). Written ONLY from `applyGesture`, i.e. only by a live mouse:
    /// the staging seam drives `advanceGesture` directly and has no pointer to
    /// hold still, so it can never arm a clock.
    @State private var heldEdgePointer: PianoRollEdgeRepeat.HeldPointer?
    /// When the last live `onChanged` arrived — the clock's only way to tell a
    /// held pointer from a moving one. `ContinuousClock` rather than `Date`
    /// because this is an elapsed-time question and must not move when the wall
    /// clock does.
    @State private var lastPointerEventAt: ContinuousClock.Instant?
    /// m25-r — the held-at-edge repeat clock, alive only while a content drag
    /// is in flight.
    ///
    /// ⚠️ **A CLOCK THAT OUTLIVES ITS GESTURE SCROLLS A SURFACE NOBODY IS
    /// TOUCHING, so it has three teardowns and needs all three** — the
    /// `flagsMonitor` shape above, for the same reason. `endGesture` stops it on
    /// every normal release; `reseedFromExternalMutation` stops it on the m18-i
    /// cancel, which has no `onEnded`-shaped end at all; `.onDisappear` stops it
    /// on the clip switch that recreates this view under a live drag.
    @State private var edgeRepeatTask: Task<Void, Never>?
    /// ⭐ THE ROLL'S HOVER FACILITY (m25-g) — the live pointer position over the
    /// note grid, in grid CONTENT coordinates, or nil when the pointer is away.
    ///
    /// Before this the roll tracked no hover at all: `hoverCursor(resolve:)`
    /// resolved a cursor per point through an `NSTrackingArea` and threw the
    /// point away, so nothing here could DRAW at the pointer. **One reader feeds
    /// every consumer** — the roadmap's *"Shares the hover facility with m25-o
    /// and m25-g — build ONE, not three"* — and the precedence between what
    /// those consumers can be over lives in `PianoRollHover.target`, not here.
    @State private var hoverPoint: CGPoint?
    /// Whether ⌘ is down RIGHT NOW (m25-o) — the roll's only piece of live
    /// modifier state, and the only reason it exists is that the affordance the
    /// user asked for has to appear WITHOUT the mouse moving: *"cursor turns into
    /// some vertical sign signaling that it is ready to move play head."*
    /// `.onContinuousHover` and the `hoverCursor` tracking area are both driven by
    /// pointer MOVEMENT, so neither can see a key press. Fed by `flagsMonitor`.
    @State private var commandHeld = false
    /// Whether ⇧ is down RIGHT NOW (m25-x), from the SAME monitor.
    ///
    /// ⭐ **ADDED BECAUSE THE COMMENT THAT REFUSED IT BECAME MEASURABLY FALSE.**
    /// `pointerModifiers` used to carry a note reading *"tracking ⇧ would buy no
    /// pixel and would double the monitor's wake-ups"*. Both halves are now
    /// wrong. It buys a pixel: `PianoRollHover.target` suppresses the group-scale
    /// bar under any TOGGLING chord, and ⇧ is one, so without this flag the bar
    /// would keep advertising a scale ⇧-click refuses — the same lie m25-x
    /// exists to remove, one degree quieter. And it doubles nothing: the monitor
    /// matches `.flagsChanged`, which already fires on every ⇧ press and release;
    /// the handler already ran and simply threw the ⇧ bit away.
    @State private var shiftHeld = false
    /// The `.flagsChanged` monitor behind `commandHeld`/`shiftHeld` (m25-o,
    /// m25-x), alive ONLY while the pointer is over the note grid.
    ///
    /// ⚠️ **A LOCAL MONITOR THAT OUTLIVES ITS VIEW IS A LEAK, so this has three
    /// independent teardowns and needs all three.** The pointer leaving the grid
    /// (`hoverPoint` going nil) stops it — that is also what makes the affordance
    /// revert when the user moves off the surface. `.onDisappear` stops it — a
    /// clip switch recreates this view (`.id(clip.id)`), and hover-exit is NOT
    /// guaranteed to fire when a view is torn down under the pointer, so without
    /// this one every clip switch made during a hover would strand a monitor.
    /// And `startFlagsMonitor` is idempotent, so a doubled start cannot orphan the
    /// first registration behind an overwritten handle.
    @State private var flagsMonitor: Any?
    /// The rubber band the grid is DRAWING right now, in grid content
    /// coordinates (m23-ek-1) — nil at rest, which is the only honest way to say
    /// "no band is in flight". This one `@State` feeds both the overlay and the
    /// seam's echo, so the reported rect is the drawn rect by construction.
    @State private var marqueeBand: CGRect?
    /// Where a STAGED gesture pressed (`debug.pianoRollMarquee {act:"begin"}`).
    /// A synthesized step carries no `DragGesture.Value`, so the press point has
    /// to be remembered for the `changed`/`end` steps to measure travel from —
    /// which is exactly what makes the seam able to exercise the real promotion
    /// threshold instead of bypassing it. Nil in normal (mouse) use.
    @State private var marqueeStageOrigin: CGPoint?
    /// Identifies THIS roll instance to `PianoRollNoteSelectionBridge`, so an
    /// outgoing instance's teardown cannot blank the report of the incoming one
    /// on a clip switch (the m23-x race, measured — see `clearSurface(from:)`).
    @State private var reportToken = UUID()
    /// Live horizontal-scroll offset of the note grid, read from the grid's
    /// content geometry so the frozen scrub strip above the grid maps its local x
    /// back to a content beat even when the grid is scrolled. Only changes on a
    /// horizontal scroll (never on a transport tick), so it stays off the playback
    /// redraw path.
    @State private var gridScrollX: CGFloat = 0
    /// The editor panel's full width, read once from a background GeometryReader
    /// (the `gridScrollReader` idiom). Feeds the m18-f wide-window rule: every
    /// horizontal band draws at `max(content, viewport)` so the grid reaches the
    /// panel's right edge instead of leaving dead glass. Changes only on a window
    /// or splitter resize — never on a transport tick or playback frame.
    @State private var panelWidth: CGFloat = 0
    /// The state a live zoom measures its anchor FROM (m25-b-3) — the roll's
    /// `ArrangeZoom.PinchState`, reduced to exactly the three arguments
    /// `ArrangeZoom.offsetPreservingAnchor` takes, so the formula stays in its one
    /// shared home and this type carries nothing but the memo.
    ///
    /// ⚠️ **NON-NIL MEANS "A GESTURE OWNS THE ANCHOR", and that is the whole
    /// point.** A pinch is CUMULATIVE (`MagnifyGesture.magnification` measures off
    /// the gesture start, not off the last tick), so every tick must rescale from
    /// the START scale AND re-pin the START anchor. Deriving the anchor afresh
    /// each tick from the live `gridScrollX` would feed the zoom's own motion back
    /// into it: a scroll request that has not landed yet reads as a different
    /// anchor beat, and the beat under the pointer would wander through the pinch.
    /// The arrange met this first and answered it the same way (`PinchState` —
    /// "measures off a FIXED anchor").
    private struct ZoomAnchorBase: Equatable {
        /// The scale the anchor was measured at.
        var ppb: CGFloat
        /// The scroll offset it was measured at.
        var offset: CGFloat
        /// The anchor's VIEWPORT-relative x — invariant for the whole gesture,
        /// because the pointer does not move during a pinch (the m25-r
        /// `HeldPointer.localX` argument, one gesture over).
        var anchorScreenX: CGFloat
    }
    @State private var zoomAnchorBase: ZoomAnchorBase?
    /// A transient inline reason shown when the delete-bar button is pressed
    /// while it can't act (m21-c bar-ops honesty) — the m17-c refusal-bubble
    /// idiom: amber, verbatim prose, auto-clearing.
    @State private var barOpsNotice: String?
    @State private var barOpsNoticeTask: Task<Void, Never>?
    /// The auto-extend refusal currently standing over the grid (m25-a-2), and
    /// its auto-clear task — the `barOpsNotice` pair one surface over, holding
    /// the store's message VERBATIM.
    ///
    /// ⚠️ **THE VIEW HOLDS THE WORDS, NEVER THE REASON.** This is a `String?`
    /// and not a `ClipAutoExtend.ExtendOutcome` on purpose: the moment this view
    /// could switch on the outcome, composing the sentence here would be one
    /// small edit away, and that is the second home m25-a-2 exists to prevent.
    @State private var autoExtendNotice: String?
    @State private var autoExtendNoticeTask: Task<Void, Never>?
    /// The content x follow last asked every band to put at its leading edge
    /// (m23-c2), plus the nonce that makes a repeat of the same x still apply. The
    /// bands' `ScrollViewReader`s watch the nonce; the markers size off the x.
    @State private var followTargetX: CGFloat = 0
    @State private var followNonce = 0
    /// Live VERTICAL scroll offset of the editor, and its viewport height (m25-b-2).
    /// The `gridScrollX` / `panelWidth` siblings for the pitch axis — read from the
    /// scroller's own geometry, so the minimap's viewport rectangle is drawn from
    /// where the editor ACTUALLY sits and never from a predicted value. Both change
    /// only on a scroll or a resize, never on a transport tick.
    @State private var gridScrollY: CGFloat = 0
    @State private var editorViewportHeight: CGFloat = 0
    /// The content y the VERTICAL scroller is being asked to put at its top, plus
    /// the nonce that makes a repeat of the same y still apply (the
    /// `followTargetX`/`followNonce` idiom, one axis over). Written ONLY by a
    /// minimap jump — follow never touches the pitch axis (`:1598-1606`).
    @State private var verticalTargetY: CGFloat = 0
    @State private var verticalNonce = 0
    @FocusState private var isFocused: Bool

    private static let keyboardWidth: CGFloat = 54
    /// Height of the frozen scrub strip pinned to the top of the note grid.
    ///
    /// m25-f-5 moved the number itself into `DAWAppKit.PianoRollScrubRuler.height`
    /// — the ONE home, beside the tick/label geometry that has to fit inside it,
    /// where a test can assert the ladder still clears the band. It is unchanged
    /// at 18: the ruler treatment had to fit the vertical budget already spent,
    /// because `PanelLayoutStore.editorFractionRange` caps the editor pane at 0.55
    /// and m25-b contests every point of it.
    private static let scrubStripHeight: CGFloat = PianoRollScrubRuler.height
    /// Stable density key for this panel. Internal (the `MixerView.panelID`
    /// shape) since m23-t so `debug.pianoRollBarOps` reports the density from
    /// the SAME constant the view reads, never a re-typed `"pianoRoll"`.
    static let panelID = "pianoRoll"
    /// Coordinate space naming the grid's horizontal scroll viewport, so the
    /// content's leading edge reports the live scroll offset.
    private static let gridScrollSpace = "pianoRollGridScroll"
    /// Follow anchors (m23-c2) — one per horizontally scrolling band. All three
    /// scroll to the SAME content x, computed once against the grid, so a page turn
    /// can never leave the note grid and the velocity lane disagreeing about where
    /// the transport is (the m23-c1 law, which the bands' independent scrollers
    /// would otherwise break the moment follow moved only one of them).
    private static let gridFollowMarkerID = "pianoRollGridFollowMarker"
    private static let velocityFollowMarkerID = "pianoRollVelocityFollowMarker"
    /// Coordinate space naming the editor's VERTICAL scroll viewport (m25-b-2), and
    /// the anchor a minimap jump scrolls that axis to.
    private static let editorVerticalScrollSpace = "pianoRollEditorVerticalScroll"
    private static let verticalJumpMarkerID = "pianoRollVerticalJumpMarker"

    init(clip: Clip, beatsPerBar: Int, positionBeats: Double, isPlaying: Bool,
         densityStore: PanelDensityStore,
         appSnap: ClipSnap = .bar,
         layout: PanelLayoutStore, follow: FollowPlayheadModel,
         onCommit: @escaping (_ notes: [MIDINote], _ extendToCover: Set<UUID>) -> String?,
         onSeek: @escaping (Double) -> Void,
         onDeleteTimeRange: @escaping (_ startBeat: Double, _ lengthBeats: Double) -> Clip?,
         onInsertTimeRange: @escaping (_ atBeat: Double, _ lengthBeats: Double) -> Clip?,
         onOpenQuantize: @escaping () -> Void,
         onOpenHumanize: @escaping () -> Void = {},
         onCommitControllerLane: @escaping (_ type: MIDIControllerType, _ points: [MIDIControllerPoint]) -> Clip?,
         onCopyNotes: @escaping ([MIDINote]) -> Void = { _ in },
         onCutNotes: @escaping (_ copied: [MIDINote], _ remaining: [MIDINote]) -> Bool
             = { _, _ in false },
         onPasteNotes: @escaping ([MIDINote], Set<UUID>) -> String? = { _, _ in nil },
         clipboardNotes: [MIDINote] = [],
         onClose: @escaping () -> Void,
         onEscape: @escaping () -> Bool = { false },
         onAudition: @escaping (_ pitches: [Int], _ velocity: Int) -> Void = { _, _ in },
         onFocusChange: @escaping (Bool) -> Void = { _ in },
         onEngage: @escaping () -> Void = {},
         onDeleteKey: @escaping () -> Bool = { false },
         stepSequencer: StepSequencerBridge = StepSequencerBridge(),
         isDrumKit: Bool = false,
         noteSelection: PianoRollNoteSelectionBridge = PianoRollNoteSelectionBridge(),
         onBarOpsStyle: @escaping (_ role: String, _ text: String?, _ ink: Color?) -> Void
             = { _, _, _ in }) {
        self.clip = clip
        self.beatsPerBar = beatsPerBar
        self.positionBeats = positionBeats
        self.isPlaying = isPlaying
        self.densityStore = densityStore
        self.appSnap = appSnap
        self.layout = layout
        self.follow = follow
        self.onCommit = onCommit
        self.onSeek = onSeek
        self.onDeleteTimeRange = onDeleteTimeRange
        self.onInsertTimeRange = onInsertTimeRange
        self.onOpenQuantize = onOpenQuantize
        self.onOpenHumanize = onOpenHumanize
        self.onCommitControllerLane = onCommitControllerLane
        self.onCopyNotes = onCopyNotes
        self.onCutNotes = onCutNotes
        self.onPasteNotes = onPasteNotes
        self.clipboardNotes = clipboardNotes
        self.onClose = onClose
        self.onEscape = onEscape
        self.onAudition = onAudition
        self.onFocusChange = onFocusChange
        self.onEngage = onEngage
        self.onDeleteKey = onDeleteKey
        self.stepSequencer = stepSequencer
        self.isDrumKit = isDrumKit
        self.noteSelection = noteSelection
        self.onBarOpsStyle = onBarOpsStyle
        _model = State(initialValue: PianoRollModel(
            notes: clip.notes ?? [],
            clipLengthBeats: clip.lengthBeats
        ))
        _controllerModel = State(initialValue: ControllerStripModel(
            lanes: clip.controllerLanes,
            clipLengthBeats: clip.lengthBeats
        ))
    }

    /// The panel's live density (Simple default), read from the shared store.
    private var mode: PanelDensity { densityStore.density(forPanel: Self.panelID) }

    /// **THE grid this surface applies** — every gesture and the drawn grid read
    /// this, never `snap` and never `appSnap`.
    ///
    /// ⚠️ **A THIN READ OF A TESTED CONTRACT, DELIBERATELY (m25-ab).** The rule —
    /// app-level OFF wins, else Simple locks to `.beat`, else the roll's pick —
    /// lives in `SnapResolution.effective`, the `ClipSnap.effective` precedent.
    /// Inlining any part of it here would rebuild the second home this item exists
    /// to remove; the answer to "what snap applies" must be derivable in exactly
    /// one place, and that place must be headless-testable.
    private var effectiveSnap: SnapResolution {
        SnapResolution.effective(appSnap: appSnap, density: mode, picked: snap)
    }

    /// Violet whenever the clip is AI-touched, else playback cyan.
    ///
    /// The AI branch is taken ONCE, here, and everything else — the fill colour,
    /// and (m25-i) the luminance the on-pill pitch-label ink is picked from —
    /// derives from this one hex. Two branches agreeing today is how a violet
    /// pill ends up wearing the ink computed for a cyan one.
    private var noteTintHex: UInt32 { PianoRollGrid.tintHex(isAI: clip.isAIGenerated) }
    private var noteColor: Color { Color(hex: noteTintHex) }

    // MARK: - Step sequencer (m23-cq-1)

    /// Which editor this pane is showing — the user's pick if they made one,
    /// else the track's kind (a drum kit opens in STEPS). ONE home:
    /// `ClipEditorModePolicy`.
    private var editorMode: ClipEditorMode { stepSequencer.mode(isDrumKit: isDrumKit) }

    /// The step size the grid draws at: Simple locks 1/16, Pro honours the
    /// picker — the `ClipSnap.effective` shape, so flipping to Simple and back
    /// restores the pick. This is what keeps the panel's SIMPLE/PRO chip from
    /// becoming a do-nothing toggle while the sequencer is the visible band.
    private var effectiveStepResolution: SnapResolution {
        stepSequencer.effectiveResolution(density: mode)
    }

    /// The resolved grid, built from the LIVE draft — so the lanes and the
    /// columns follow an edit (or a wire-side mutation) without a second seed.
    /// ONE value feeds the drawing, the hit test and the toggle.
    private var stepGeometry: StepSequencerGeometry {
        StepSequencerGeometry.make(
            isDrumKit: isDrumKit, notes: model.draft, clipLengthBeats: model.clipLengthBeats,
            resolution: effectiveStepResolution, beatsPerBar: beatsPerBar)
    }

    /// TOGGLE A CELL — the sequencer's whole edit vocabulary, and the ONE
    /// handler both the click and `debug.stepSequencer` route through.
    ///
    /// It writes the SAME draft the piano roll edits and submits through the
    /// SAME `commit()` funnel (m23-al R6, which is also where the engagement
    /// happens — a click here is the user acting inside the editor pane). Two
    /// editors committing by different routes would disagree about a clip and
    /// undo would differ by which one you had used.
    private func applyStepToggle(_ cell: StepCell) {
        let outcome = StepSequencerEdit.toggle(
            notes: model.draft, cell: cell, geometry: stepGeometry)
        model.replaceDraft(outcome.notes)
        commit()
    }

    // MARK: - Wide-window band widths (m18-f — DESIGN-LANGUAGE "Wide windows")

    /// The horizontal viewport every band scrolls in: the panel minus the shared
    /// 54 pt gutter (keyboard sidebar / VEL label / CTRL label — all
    /// `keyboardWidth`-wide by design, so one number serves all three bands).
    private var bandViewportWidth: CGFloat { max(0, panelWidth - Self.keyboardWidth) }

    /// Drawn width of the note grid AND the velocity lane (they share the grid's
    /// beat→x space, so they must stay width-identical): content, extended to the
    /// viewport at wide windows. The extension is shaded latent space — the
    /// out-of-clip shade keeps the playable window honest.
    private var gridDrawnWidth: CGFloat {
        PianoRollModel.drawnWidth(content: model.contentWidth, viewport: bandViewportWidth)
    }

    /// Drawn width of the controller canvas — its own model's content width
    /// (CC points can outrun notes and vice versa), same viewport extension.
    private var controllerDrawnWidth: CGFloat {
        PianoRollModel.drawnWidth(content: controllerModel.contentWidth, viewport: bandViewportWidth)
    }

    private enum ActiveDrag: Equatable {
        case none
        case click(UUID?)     // shift-click or empty — resolved on drag end
        case move
        case resize(UUID)
        /// A RUBBER BAND, promoted out of `.click(nil)` once the pointer
        /// travelled `PianoRollMarquee.dragSlop` (m23-ek-1).
        ///
        /// ⚠️ PROMOTION INSIDE `gridDrag`, NOT A SECOND GESTURE, and the arrange's
        /// `.simultaneousGesture(marqueeGesture)` remedy deliberately does NOT
        /// transfer. There, the competitors are two `onTapGesture`s, which a
        /// `minimumDistance` excludes cleanly. HERE the competitor is
        /// `gridDrag` itself — a `DragGesture(minimumDistance: 0)` that already
        /// claims every press on the grid and calls `clearSelection()` on
        /// release. A simultaneous band would run CONCURRENTLY with it and both
        /// `onEnded` bodies would fire, one applying the band's selection and
        /// the other clearing it, at an ordering that is SwiftUI's and is not
        /// observable from this tree (the m23-bw law). No `minimumDistance` can
        /// exclude a gesture that already began at 0.
        ///
        /// What promotion buys, each of which is a hazard that then needs NO
        /// handling:
        ///  • CLICK-TO-DESELECT SURVIVES BYTE-IDENTICALLY — no travel means no
        ///    promotion, so the `.click(nil)` branch runs exactly as before.
        ///  • ⭐ NO TAP-SUPPRESSION WINDOW IS NEEDED AT ALL. The arrange carries
        ///    `marqueeEndedAt` / `consumeMarqueeClickSuppression` because a
        ///    marquee's mouse-up there can synthesize a SEPARATE tap that would
        ///    seek. Here the click IS this gesture's own `.click` branch, which
        ///    promotion has already left. **Do not "restore consistency with the
        ///    arrange" by adding a suppression flag: it could only cause bugs.**
        ///  • A press on a NOTE can never become a band — promotion is gated on
        ///    `.click(nil)`, and a press on a note is `.click(id)` or `.move`.
        ///  • The double-tap add is untouched: a double-tap has no travel.
        ///
        /// `base` is the selection frozen at promotion, which is provably the
        /// selection at PRESS: between the two, the only code that runs is
        /// `advanceGesture`'s `.click` branch → `advanceMarquee`, and every path
        /// through it that has not yet crossed `dragSlop` returns without
        /// touching the model. (The pre-ek-1 spelling of this argument — "the
        /// `.click` branch is `break`" — no longer describes the code, but the
        /// property it asserted still holds and is what `base` depends on.)
        case marquee(origin: CGPoint, base: Set<UUID>, additive: Bool)
        /// GROUP COMPRESS / EXTEND (m25-g) — the selection's timing is being
        /// scaled by the handle at `edge`, anchored on the opposite edge.
        ///
        /// ⚠️ A STATE OF `gridDrag`, NOT A NEW GESTURE, and that is the m23-ek-1
        /// precedent rather than a shortcut: `gridDrag` is a
        /// `DragGesture(minimumDistance: 0)` that already claims every press on
        /// this surface, so a second gesture would run CONCURRENTLY with it and
        /// both `onEnded` bodies would fire — one committing a scale, the other
        /// clearing the selection — at an ordering this tree cannot observe
        /// (m23-bw). It also keeps `EditorSurfaceOwnershipSiteTests`'
        /// gesture-attachment count at 8, and means the staging seam
        /// (`applyMarqueeStage`) drives this gesture through the SAME handlers
        /// the mouse does, for free.
        case groupScale(PianoRollGroupScale.Edge)
        /// SCRUB BY THE LINE (m25-o-2) — the transport playhead was grabbed
        /// where it is drawn, and the drag moves it. `scrubbing` goes true once
        /// the press crosses `PianoRollPlayhead.scrubSlop` and STAYS true, so a
        /// drag that wanders back under the slop keeps seeking.
        ///
        /// ⚠️ A STATE OF `gridDrag`, for the same reason `.groupScale` and
        /// `.marquee` are: a second gesture would run CONCURRENTLY with the
        /// `minimumDistance: 0` drag that already claims every press here, and
        /// both `onEnded` bodies would fire at an ordering this tree cannot
        /// observe (m23-bw). It also holds the gesture-attachment count at 8.
        ///
        /// ⚠️⚠️ **THE SLOP LIVES IN THE PAYLOAD, NOT IN A `@State` FLAG, AND THAT
        /// IS DELIBERATE.** The arrange keeps the equivalent in
        /// `@State playheadScrubbing`, which it must then remember to reset —
        /// and this view has a `.cancelled` path (m18-i) the arrange does not,
        /// where a mid-gesture reseed swallows the rest of the drag. A separate
        /// flag could strand itself true there and make the NEXT press seek
        /// without travelling. Carried in the case, it cannot outlive the
        /// gesture: `activeDrag = .none` erases it by construction, exactly as
        /// `.marquee`'s frozen origin is erased.
        case playheadDrag(scrubbing: Bool)
        /// An external mutation reseeded the models mid-gesture (m18-i): the
        /// rest of the drag is swallowed — no apply, no commit, and no restart
        /// (`onChanged` only begins a gesture from `.none`) — so a half-dragged
        /// ghost never lands on the new content. Cleared on gesture end.
        case cancelled
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                // The bar-ops refusal bubble hangs below the header over the
                // grid; keep the header's overflow above the editor band.
                .zIndex(1)
            Divider().overlay(DAWTheme.hairline)
            // ONE pane, two editors over ONE clip (m23-cq-1). The step grid
            // REPLACES the whole note-editor stack rather than sitting beside
            // it: velocity and controller lanes are note-grid chrome, and a
            // second copy of the editor's vertical budget is exactly what makes
            // an editor pane unusable at the window floor.
            if editorMode == .steps {
                stepSequencerBand
                    .explainable(.stepSequencerGrid)
            } else {
                editor
                    .explainable(.pianoRollGrid)
                if mode == .pro {
                    Divider().overlay(DAWTheme.hairline)
                    velocitySection
                        .explainable(.pianoRollVelocity)
                    Divider().overlay(DAWTheme.hairline)
                    controllerSection
                        .explainable(.pianoRollControllers)
                }
            }
        }
        .glassPanel()
        .background { panelWidthReader }
        .focusable()
        .focused($isFocused)
        // m23-cf (second pass): DELETE goes through the app's ONE routing
        // decision, not through a rule spelled here. This handler and
        // `ArrangeDeleteKey`'s and `AutomationLaneEditor`'s are three focus-gated
        // claimants for one key, and SwiftUI picks between them in a way this
        // tree measured to be a coin flip — so all three ask the same question
        // and the answer no longer depends on who was focused.
        //
        // ⚠️ THE WORK STILL HAPPENS HERE, one hop later: when the routing names
        // this roll the app bumps `noteSelection.deleteNonce`, and the
        // `.onChange` below runs `deleteSelection()` + `commit()` — the exact
        // three lines this closure used to run inline, in the exact place they
        // can reach `model`, which is `@State private`. That is also why the
        // R6 engagement funnel and the undo journalling are unchanged.
        //
        // ⚠️ `.ignored` ONLY WHEN NOTHING ANYWHERE OWNS THE KEY, so an unclaimed
        // DELETE keeps propagating to ancestors exactly as it does today.
        // ⚠️ m23-fi: EXACT SPELLING PINNED by `DeleteKeySiteTests.rollRoutes` —
        // no probe counter here; the substitute is `deleteKeyFunnelSeq` under a
        // ⇧ chord (see `KeyPressProbe`).
        //
        // ⭐⭐ m23-fk — THE KEY LIST IS THE FIX. `.onKeyPress` matches on the
        // event's CHARACTERS, `KeyEquivalent.delete` is 0x08 (BACKSPACE) and the
        // ⌫ key sends 0x7F (DELETE), so `.onKeyPress(.delete)` never fired here.
        // MEASURED ON THIS MOUNT with a note selection armed: an event carrying
        // 0x08 deleted all three notes, the SAME event carrying 0x7F deleted
        // none. `.delete` is kept (free, and covers a future normalisation);
        // `.deleteForward` (0xF728) is added because ⌦ really sends it. See
        // `ContentView.ArrangeDeleteKey` for the full argument and the
        // no-double-fire measurement.
        // ⚠️⚠️ `phases: [.down]` IS LOAD-BEARING — see `ContentView.ArrangeDeleteKey`
        // for the measurement. Omitting it admits `.repeat` presses, and the
        // m23-cf-3 monitor passes auto-repeats through, so a HELD ⌫ walked from
        // "delete the notes" to "delete the clip" in one measured sequence.
        .onKeyPress(keys: [KeyEquivalent("\u{7F}"), .delete, .deleteForward],
                    phases: [.down]) { _ in
            onDeleteKey() ? .handled : .ignored
        }
        // ESCAPE leaves the MAXIMIZED editor mode (m25-b-1) — the PRIMARY mount,
        // because this view asserts focus on appear and is where the user's eyes
        // are when the mode is on. It routes to the app's ONE decision
        // (`AppModel.handleEditorEscape`), which the arrange workspace's backstop
        // mount also calls; a mode that fills the window must not have exactly one
        // way out, and the header toggle is the other.
        //
        // ⚠️ `.ignored` UNLESS THE DECISION CONSUMED IT — outside the maximized
        // mode this view claims nothing new, so Escape propagates exactly as it
        // did before. ⚠️ `.escape` needs no `\u{1B}` companion: unlike ⌫ (0x08 vs
        // 0x7F, the m23-fk trap two lines up), `KeyEquivalent.escape` IS 0x1B, so
        // the spelling and the key agree.
        .onKeyPress(.escape) {
            onEscape() ? .handled : .ignored
        }
        .onAppear { isFocused = true }
        // m21-c: report key focus so the app routes ⌘+/⌘−/⌘0 to THIS editor's
        // zoom while it is focused (the View-menu key equivalents fire before
        // any focused view sees the key, so routing lives app-side).
        .onChange(of: isFocused, initial: true) { _, focused in onFocusChange(focused) }
        // m23-x: publish whether THIS editor holds a note selection — the same
        // test the DELETE handler just above applies to decide whether to
        // consume the key or let it fall through to the arrange. The arrange's
        // arrow-key nudge refuses on focus AND this, so ← with notes selected
        // edits notes rather than sliding the whole clip underneath the user.
        // `.onChange` (not `body`) for the `onFocusChange` reason: this gates a
        // keyboard path, so it must be an observable transition, and
        // `initial: true` means a roll that opens with a selection already
        // reports it rather than waiting for the first change.
        .onChange(of: model.selection.isEmpty, initial: true) { _, empty in
            noteSelection.report(hasSelection: !empty)
        }
        // m23-x: the STAGED NOTE SELECTION (the `follow.externalScrollNonce`
        // pattern — watch the NONCE, so the same state asked for twice still
        // applies). This is the only way anything outside can reach `model`,
        // which is `@State private`.
        //
        // TWO PRODUCERS SINCE m23-ak, and this comment used to name only the
        // first. (1) The debug seam, `debug.arrangeSelection
        // {act:"pianoRollNotes"}`, which can ask for either state. (2) THE APP
        // ITSELF: `AppModel.arrangeSelection`'s `didSet` calls
        // `dropForWidenedArrangeSelection()` when the arrange selection grows
        // past this clip, so a user who selects notes here and THEN shift-clicks
        // two more clips gets → and DELETE aimed at the three clips rather than
        // at the notes. That path always lands in the `else` below. No logic
        // here changed for it — the production verb reuses this nonce
        // deliberately, so the roll needs no second channel — but reading this
        // as "gate-only" would be wrong, and a stale doc comment on the seam
        // that gates a keyboard path is the kind of defect this file has paid
        // for before.
        //
        // ⭐ THE SELECT-ALL BRANCH IS NOW A CALL, NOT AN EXPRESSION (m25-s). It
        // used to spell `model.selection = Set(model.draft.map(\.id))` inline;
        // that rule moved to `PianoRollModel.selectAllNotes()` so the user's ⌘A
        // (`selectAllNonce`, below) executes the SAME verb rather than a second
        // copy of it. Behaviour here is unchanged, character for character.
        .onChange(of: noteSelection.stageNonce) { _, _ in
            if noteSelection.stagedSelectAll {
                model.selectAllNotes()
            } else {
                model.clearSelection()
            }
        }
        // m25-s: ⌘A / EDIT ▸ SELECT ALL reaching the roll. The user asked for it
        // 2026-08-13 ("when in node editor and user uses keyboard shortcut
        // 'select all'/cmd+A - it should select all the notes in the editor").
        //
        // ⚠️ A SEPARATE NONCE FROM `stageNonce` ABOVE, THOUGH THEY NOW RUN THE
        // SAME LINE. That one is the m23-x DEBUG seam and also carries m23-ak's
        // production "give the keys back" clear; a user keystroke must not depend
        // on a test affordance, and a ⌘A must not be indistinguishable from a
        // staged CLEAR at this `.onChange`. The bridge's `selectAllNonce` doc
        // carries the full argument.
        //
        // ⚠️ NO `commit()`, AND NOT AN OVERSIGHT. Selecting touches `selection`
        // and never `draft`, so there is nothing to journal — an undo entry for
        // "I selected some notes" would be noise the user has to step back
        // through. `EditorSurfaceOwnershipSiteTests` pins this file's `commit(`
        // count at 7 partly so that a selection path cannot quietly acquire one.
        //
        // ⚠️ NO `onEngage()` EITHER. Engagement is what ROUTED this keystroke
        // here in the first place (`SelectAllMenuPolicy` reads
        // `activeEditorSurface`); reporting it back would be a feedback loop, and
        // the same site test pins the `onEngage()` count.
        .onChange(of: noteSelection.selectAllNonce) { _, _ in
            model.selectAllNotes()
        }
        // m23-cf: EDIT ▸ DELETE reaching the roll — and, since the second pass,
        // THE DELETE KEY TOO. Neither can call `model.deleteSelection()` itself
        // (`model` is `@State private`), so both bump `deleteNonce` and this
        // applies it.
        //
        // ⭐ THIS IS NOW THE ROLL'S ONE NOTE-DELETE BODY, not "the menu's copy of
        // the key's". `.onKeyPress(.delete)` above used to run these same three
        // lines inline; it now routes through `AppModel.handleDeleteKey`, which
        // lands right back here. Two routes, one funnel, one journal entry shape
        // — so undo behaves identically whether the user pressed the key, picked
        // Edit ▸ Delete, or used the grid's context menu.
        //
        // THE GUARD IS NOT REDUNDANT with the routing decision. That decision
        // reads `noteSelection.hasSelection`, which the roll reports on a
        // TRANSITION; this is the roll's own live selection at the instant the
        // request lands. If the two ever disagree, the ROLL wins and the request
        // becomes a no-op rather than deleting something the user could not see
        // selected. Same argument for the menu item's disabled state.
        .onChange(of: noteSelection.deleteNonce) { _, _ in
            guard !model.selection.isEmpty else { return }
            model.deleteSelection()
            commit()
        }
        // m23-ek-3: EDIT ▸ CUT / COPY / PASTE reaching the roll, and the roll's
        // own context-menu entries. Same reason as `deleteNonce` above — the menu
        // cannot touch `model`, which is `@State private` — and a fourth nonce
        // rather than a fourth meaning on `stageNonce`, which routes
        // `stagedSelectAll == false` straight to `clearSelection()` and would
        // wipe the very selection a copy was about to read.
        //
        // ⚠️ THE ROLL RESOLVES ALL THREE, NOT THE MENU. Copy/cut need
        // `model.selection` and `model.draft`; paste needs the LIVE playhead and
        // this roll's EFFECTIVE SNAP. None of it is visible from a `Commands`
        // body, and the bridge's `surface` echo is one body pass behind a
        // selection change (measured — see `awaitPianoRollMarqueeApplied`), so
        // reading it here instead would be intermittently wrong.
        .onChange(of: noteSelection.clipboardNonce) { _, _ in
            applyClipboardRequest(noteSelection.stagedClipboardVerb)
        }
        // m23-ek-1: the STAGED GRID GESTURE (`debug.pianoRollMarquee`) — watch
        // the NONCE, so the same step asked for twice still applies (a gate must
        // be able to drag to the same point twice). Runs `applyMarqueeStage`,
        // which routes into the SAME press/promote/release handlers the mouse
        // runs, so the seam cannot drift from the pointer.
        .onChange(of: noteSelection.marqueeStageNonce) { _, _ in
            guard let stage = noteSelection.marqueeStage else { return }
            applyMarqueeStage(stage)
        }
        // m23-ek-1: the surface report — the LADDER (`rowHeight`, the live
        // `pixelsPerBeat`), the content, and the selection.
        //
        // `initial: true` and keyed on the whole state, so a BARE
        // `debug.pianoRollMarquee {}` can answer the scales a fixture must derive
        // its coordinates FROM before any gesture has run. A fixture that
        // hardcoded 14 and 32 would pass at defaults and silently test nothing at
        // any other zoom — `pixelsPerBeat` is driven by the persisted, zoomable
        // `PanelLayoutStore.pianoRollPPB`.
        //
        // This path does NOT bump the marquee report sequence: a relayout must
        // never satisfy a bounded wait that is standing on a staged gesture step.
        .onChange(of: surfaceState, initial: true) { _, state in
            noteSelection.reportSurface(token: reportToken, state)
        }
        // m23-cq-1: the STAGED CELL TOGGLE (`debug.stepSequencer {act:"toggle"}`)
        // — watch the NONCE, so toggling one cell on and then off (two requests
        // with identical payloads) applies twice. It runs `applyStepToggle`, the
        // SAME handler the click runs, so the seam cannot drift from the mouse.
        //
        // GUARDED ON THE VISIBLE MODE: with the piano roll showing there is no
        // grid, no cell, and nothing the user could have clicked — a toggle
        // applied anyway would be a wire-only edit wearing a UI seam's name.
        .onChange(of: stepSequencer.toggleNonce) { _, _ in
            guard editorMode == .steps, let cell = stepSequencer.stagedCell else { return }
            applyStepToggle(cell)
        }
        // m23-cq-1: entering the step grid drops any NOTE selection.
        //
        // Not tidiness — the grid draws no selection, so a selection surviving
        // the switch is state the user cannot see, and `noteSelection` publishes
        // exactly that state to Edit ▸ Delete and to the arrange's arrow-key
        // nudge. A menu that deletes invisible notes is the m23-x latched-claim
        // failure with the user's music at stake.
        .onChange(of: editorMode, initial: true) { _, newMode in
            if newMode == .steps { model.clearSelection() }
        }
        .onDisappear {
            onFocusChange(false)
            // m23-x: and drop the note-selection claim with it. A latched
            // `true` here would kill the arrange's arrow keys permanently once
            // the editor closed, with nothing on screen to explain why.
            noteSelection.clear()
            // m23-ek-1: same argument for the marquee echo — a latched band or
            // ladder would let the seam answer with a grid nothing is drawing.
            // Token-guarded, so a clip switch's teardown/standup race cannot
            // blank the INCOMING roll's report.
            noteSelection.clearSurface(from: reportToken)
            // m23-d: a clip switch recreates this view (`.id(clip.id)`), so the
            // disappearing instance must release whatever it was sounding.
            onAudition([], 0)
            // m25-o: and the same clip switch must not strand the ⌘ monitor. A
            // hover-exit is not guaranteed for a view torn down under the pointer,
            // so this is the teardown that actually holds.
            stopFlagsMonitor()
            // m25-r — teardown 3 of 3, the same argument one line down: a clip
            // switch recreates this view (`.id(clip.id)`) and is not guaranteed
            // to deliver an `onEnded` for a drag in flight, so the disappearing
            // instance stops its own clock.
            setEdgeRepeat(running: false)
        }
        // m21-c: ONE persisted zoom value (`panelLayout.pianoRollPPB`) feeds
        // every band's beat→x mapping — the note grid + velocity lane via
        // `model`, the controller strip via its own model — so all three
        // rescale together and never drift.
        //
        // ⭐⭐ m25-b-3 — AND THE NO-JUMP RULE RIDES HERE, ON THE CHANGE ITSELF,
        // NOT ON THE FOUR DRIVERS. See `repinZoomAnchor` for why this is the
        // funnel rather than four call sites.
        .onChange(of: layout.pianoRollPPB, initial: true) { oldPPB, ppb in
            model.pixelsPerBeat = ppb
            controllerModel.pixelsPerBeat = ppb
            repinZoomAnchor(oldPPB: oldPPB, newPPB: ppb)
        }
        // m18-i: the external-mutation seam. `.id(clip.id)` recreates this view
        // (and its seeded @State models) only on a clip IDENTITY switch; a
        // wire/arrange-side geometry op (`clip.trim`/`move`/`split`, arrange
        // bar ops, undo/redo of any) mutates the clip VALUE under the same
        // identity — without this, every band keeps drawing the pre-op
        // snapshot until a reselect. The MODELS decide staleness themselves
        // (`needsReseed`, canonical-content compare — headless-tested), so the
        // editor's own commits echoing back through the store read as equal
        // and never double-reseed (which would clobber scroll/selection/the
        // strip's chosen lane).
        .onChange(of: clip) { _, newValue in
            reseedFromExternalMutation(newValue)
        }
        // FOLLOW THE PLAYHEAD (m23-c2) — driven from the TRANSPORT observation
        // path (`positionBeats` is plain @Observable state the engine's playhead
        // handler pushes at ~30 Hz), never from a geometry callback: a `scrollTo`
        // issued inside a layout transaction moves layout but does not durably
        // update the scroller's position (m17-b, measured).
        .onChange(of: positionBeats) { _, _ in followTick() }
        // The gate's simulated pointer scroll (m23-c2) — the same band-scroll seam
        // follow uses, minus the expectation, so the manual-scroll detector sees
        // what a real drag would report.
        .onChange(of: follow.externalScrollNonce) { _, _ in
            followTargetX = follow.externalScrollX
            followNonce += 1
        }
    }

    // MARK: - Follow the playhead (m23-c2)

    /// One transport tick's follow for the roll's bands.
    ///
    /// **Off-clip policy:** when the transport sits outside the edited clip there
    /// is no line to keep in frame (m23-c1 — `lineX` is nil, and the `OffClipEdgeCue`
    /// already says which way the transport went), so follow does NOTHING. Scrolling
    /// the grid to a position the editor does not draw would be motion with no
    /// referent, and the cue is anchored to the VIEWPORT, so scrolling would not
    /// even move it.
    ///
    /// The target is computed once, against the note GRID's geometry (the band the
    /// playhead lives in), and every band scrolls to that same content x.
    private func followTick() {
        guard let localX = playheadLineX else { return }
        guard let target = follow.target(
            isEnabled: followDrives, isPlaying: isPlaying,
            playheadX: localX, viewportWidth: bandViewportWidth,
            contentWidth: gridDrawnWidth, currentOffset: gridScrollX) else { return }
        followTargetX = target
        followNonce += 1
    }

    /// The playhead's x in the GRID's content space, or nil when the transport
    /// sits outside the edited clip (m23-c1).
    private var playheadLineX: CGFloat? { playheadLineX(atPPB: model.pixelsPerBeat) }

    /// The same line, at an EXPLICIT scale.
    ///
    /// ⚠️⚠️ **THIS OVERLOAD EXISTS FOR ONE CALLER AND THE REASON IS A BUG IT
    /// PREVENTS.** `repinZoomAnchor` runs from the ppb `onChange`, whose body has
    /// ALREADY written the new scale into `model.pixelsPerBeat` — so the property
    /// above would hand it the playhead's content x at the NEW scale, while the
    /// anchor it is computing must be a screen x measured in the OLD one. The
    /// error is silent (a plausible number, a wrong anchor, content that slides
    /// exactly as far as the zoom step) and it survives every rule test, because
    /// the rules are right and only the argument is wrong. `setArrangeZoom` passes
    /// `positionBeats * old` explicitly for this same reason; the roll now says so
    /// in the type rather than in a comment. Pinned by
    /// `PianoRollZoomAnchorSiteTests`.
    private func playheadLineX(atPPB ppb: CGFloat) -> CGFloat? {
        PianoRollPlayhead.lineX(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, pixelsPerBeat: ppb)
    }

    /// Whether follow is actually DRIVING this surface right now — the enable flag
    /// AND a playhead to keep in frame.
    ///
    /// Off-clip this is false, and that matters to more than `followTick`: the
    /// manual-scroll detector reads the same predicate. Without it, a user scrolling
    /// the grid while the transport played outside the edited clip would suspend a
    /// follow that was never contesting the scroll — and the chip would show its
    /// PAUSED face for a fight that never happened, which is exactly the dishonest
    /// readout the chip exists to avoid.
    private var followDrives: Bool {
        layout.followPlayhead && playheadLineX != nil
    }

    /// A band's follow anchor: a 1 pt, layout-real, hit-test-inert marker whose
    /// LEADING edge sits at `followTargetX` — `scrollTo(..., anchor: .leading)`
    /// lands the viewport edge exactly on it (the arrange `hScrollMarker` idiom;
    /// real frames, never `.offset`, so `scrollTo` reads a true layout position).
    ///
    /// Sizing the marker re-lays-out these two empty views and nothing else: the
    /// band's width is pinned by its own `.frame`, so the marker can never grow the
    /// content — which is why follow costs no Canvas redraw and no band relayout.
    private func followMarker(_ id: String) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, followTargetX), height: 1)
            Color.clear.frame(width: 1, height: 1).id(id)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Viewport minimap (m25-b-2)

    /// Aims the editor at a point the user pressed on the corner map.
    ///
    /// ⭐⭐ **THE FOLLOW-PLAYHEAD PRECEDENCE DECISION LIVES ON THIS LINE: the
    /// horizontal jump is delivered through `scrollExternally`, the MANUAL-SCROLL
    /// seam — so a minimap jump IS a manual scroll and follow stands down.**
    ///
    /// Nothing new was invented for it. `FollowPlayheadModel`'s shipped policy
    /// already reads "a manual scroll during playback SUSPENDS follow on that
    /// surface until the transport is started again (or the chip is clicked)", and
    /// this seam produces exactly the signature that triggers it: an offset the
    /// scroller reports back that follow never asked for, with no issue in flight.
    /// The chip drops to its PAUSED face, so the stand-down is VISIBLE rather than
    /// a silent tug-of-war between the map and the transport.
    ///
    /// ⚠️ **`layout.followPlayhead` is deliberately NOT toggled off.** That flag is
    /// the single persisted ENABLE the arrange lanes read too — switching it to win
    /// a piano-roll gesture would stand follow down on a surface the user never
    /// touched, and would outlive the gesture by every future session. Suspension
    /// is per-surface runtime state that re-arms on the next play, which is what
    /// "the user wins THIS scroll" ought to mean and all it ought to mean.
    ///
    /// ⚠️ While STOPPED nothing is suspended: `reportOffset` is armed only during
    /// playback, so a jump with the transport parked simply re-baselines. There is
    /// no fight to win.
    ///
    /// The VERTICAL half cannot travel that seam — follow has no pitch axis
    /// (`:1598-1606` scopes it out on purpose) — so it rides its own target+nonce
    /// pair to the vertical scroller.
    private func jumpToMinimapTarget(_ target: CGPoint) {
        follow.scrollExternally(to: target.x)
        verticalTargetY = target.y
        verticalNonce += 1
    }

    /// The playhead's x for the MAP, which is the grid's own producer and the
    /// grid's own off-clip rule (`playheadLineX`) — so the map cannot claim a
    /// transport position the grid is not drawing.
    private var minimapPlayheadX: CGFloat? { playheadLineX }

    /// The map, or the chip that brings it back, in the editor's bottom-trailing
    /// corner. Inset clear of the scrollers' indicator overlays.
    @ViewBuilder
    private var minimapOverlay: some View {
        if layout.pianoRollMinimap {
            PianoRollMinimapView(
                notes: model.draft,
                rowHeight: model.rowHeight,
                pixelsPerBeat: model.pixelsPerBeat,
                contentWidth: gridDrawnWidth,
                contentHeight: model.contentHeight,
                scrollX: gridScrollX,
                scrollY: gridScrollY,
                viewportWidth: bandViewportWidth,
                // ⚠️ KNOWN, BOUNDED OVERSTATEMENT — recorded so it is not
                // rediscovered as a bug: this is the SCROLLER's height, and the
                // frozen scrub strip covers its top `scrubStripHeight` (18 pt), so
                // the rectangle claims ~18 pt more visible pitch than there is.
                // Deliberately NOT "corrected" by subtracting the strip: the clamp
                // ceiling must stay the scroller's OWN max offset, and a map that
                // clamped to a shorter viewport would ask for offsets the scroller
                // refuses at the bottom edge — trading 18 pt of overstatement for a
                // rectangle that disagrees with the editor about where it is. 18 pt
                // of 1792 is the cheaper error, and it is an error in the safe
                // direction (the box is never smaller than what you can see).
                viewportHeight: editorViewportHeight,
                playheadContentX: minimapPlayheadX,
                noteColor: noteColor,
                onJump: jumpToMinimapTarget,
                onCollapse: { layout.setPianoRollMinimap(false) })
                .padding(.trailing, 14)
                .padding(.bottom, 14)
        } else {
            PianoRollMinimapChip(onExpand: { layout.setPianoRollMinimap(true) })
                .padding(.trailing, 14)
                .padding(.bottom, 14)
        }
    }

    /// Reads the editor's VERTICAL scroll offset and viewport height (m25-b-2) —
    /// the `gridScrollReader` idiom on the pitch axis. A background inside the
    /// vertical scroll content (never hit-tested), updated only when the offset
    /// actually moves.
    ///
    /// ⚠️ It reports to `gridScrollY` ONLY — never to `follow.reportOffset`. Follow
    /// is a horizontal mechanism here (its whole runtime is one offset against one
    /// content width), and feeding it a second axis' reports would make every
    /// pitch scroll look like a manual horizontal scroll and suspend follow for a
    /// gesture that never contested it.
    private var editorVerticalScrollReader: some View {
        GeometryReader { geo in
            let topY = geo.frame(in: .named(Self.editorVerticalScrollSpace)).minY
            Color.clear
                .onChange(of: topY, initial: true) { _, newValue in
                    gridScrollY = -newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// Reads the editor's visible HEIGHT — the viewport the minimap's rectangle is
    /// sized from. Changes on a window/splitter resize (and on entering the m25-b-1
    /// maximized mode), never on a playback tick.
    private var editorHeightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.height, initial: true) { _, newValue in
                    editorViewportHeight = newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// The vertical jump's anchor: the `followMarker` idiom on the pitch axis — a
    /// 1 pt, layout-real, hit-test-inert marker whose TOP edge sits at
    /// `verticalTargetY`, so `scrollTo(..., anchor: .top)` lands the viewport's top
    /// exactly on it.
    ///
    /// ⚠️⚠️ **IT IS MOUNTED ON THE KEYBOARD GUTTER, AND THAT PLACEMENT IS THE WHOLE
    /// SAFETY ARGUMENT — do not "tidy" it into the grid.** `:1598-1606` records why
    /// follow's `ScrollViewReader` wraps only the horizontal scroller: a reader
    /// resolves `scrollTo` against EVERY scroll view inside its content, and an
    /// `.leading` anchor carries a y of 0.5, so a reader spanning both axes would
    /// yank the pitch view on every page turn. The vertical jump needs a reader
    /// that DOES span both axes (the horizontal scroller is inside the vertical
    /// one), so it avoids the symmetric failure by putting the anchor where the
    /// horizontal scroller cannot see it — the gutter is a SIBLING of that
    /// scroller, so only the vertical scroller can resolve this id, and being
    /// `.vertical`-only it has no horizontal axis for the `.top` anchor's x = 0.5
    /// to disturb. The grid's own follow marker stays exactly where it is.
    ///
    /// ⚠️ An `.overlay` is sized to its PARENT's bounds, so a marker taller than
    /// the gutter would be compressed and `scrollTo` would land somewhere other
    /// than `verticalTargetY`. It cannot happen here, by construction rather than
    /// by luck: the gutter is laid out at exactly `model.contentHeight`
    /// (`KeyboardSidebar.swift:125`), `verticalTargetY` has exactly ONE writer
    /// (`jumpToMinimapTarget`), and the value it writes is
    /// `PianoRollMinimap.scrollTarget`'s y — clamped to
    /// `contentHeight − viewportHeight`, hence always strictly inside the gutter.
    /// If a second writer ever appears, that argument dies with it.
    private var verticalJumpMarker: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 1, height: max(0, verticalTargetY))
            Color.clear.frame(width: 1, height: 1).id(Self.verticalJumpMarkerID)
        }
        .allowsHitTesting(false)
    }

    /// Reseeds the edit models from an externally mutated clip value (m18-i).
    /// CANCEL-THEN-RESEED for an in-flight grid gesture: the drag parks in
    /// `.cancelled` (remaining ticks swallowed — no apply, no commit, no
    /// restart) and the models clear their own drag baselines (`reseed` doc
    /// comments), so stale gesture state never edits the new content.
    private func reseedFromExternalMutation(_ clip: Clip) {
        let notes = clip.notes ?? []
        let gridStale = model.needsReseed(notes: notes, clipLengthBeats: clip.lengthBeats)
        let stripStale = controllerModel.needsReseed(
            lanes: clip.controllerLanes, clipLengthBeats: clip.lengthBeats)
        guard gridStale || stripStale else { return }
        if activeDrag != .none {
            activeDrag = .cancelled
            didMove = false
            // m25-r — teardown 2 of 3, and the one a clock cannot live without:
            // this path swallows the gesture with NO `onEnded`-shaped end, so
            // without it an external mutation mid-drag would leave a repeat
            // running against content that no longer exists.
            setEdgeRepeat(running: false)
            heldEdgePointer = nil
            lastPointerEventAt = nil
            // m23-ek-1: a live rubber band dies with the gesture, and its VISUAL
            // has to die with it. A band left on screen with no gesture behind it
            // is a ghost the user cannot dismiss, and the next release would
            // apply a selection decided against content that no longer exists.
            marqueeStageOrigin = nil
            if marqueeBand != nil {
                marqueeBand = nil
                reportMarquee(hits: [])
            }
        }
        if gridStale { model.reseed(notes: notes, clipLengthBeats: clip.lengthBeats) }
        if stripStale {
            controllerModel.reseed(lanes: clip.controllerLanes, clipLengthBeats: clip.lengthBeats)
        }
    }

    /// m23-al R6 — the NOTE-EDIT commit funnel.
    ///
    /// VERIFIED COVERAGE, NOT ASSUMED: its only callers are the roll's own
    /// `.onKeyPress(.delete)`, the double-tap add, `endGesture` when the note
    /// actually moved, and the VELOCITY LANE (`VelocityLane(…, onCommit: commit)`,
    /// which has no other route out). All four are user gestures and there is no
    /// non-gesture caller, so this cannot FALSE-engage — which is the property
    /// that makes it safe to put the call here rather than at four sites.
    ///
    /// m25-a — `extendToCover` is the AUTO-EXTEND request, and it is a parameter
    /// of the funnel rather than a fifth caller so that the two gestures that
    /// need it (double-click-to-create here, and m25-f-3's edge drag) submit
    /// through the same single store call. Default `[]` keeps the other four
    /// callers byte-identical: DELETE and the velocity lane cannot push a note
    /// past the clip end, so neither should be able to grow the clip.
    ///
    /// m25-a-2 — AND IT IS WHERE THE AUTO-EXTEND REFUSAL SURFACES, for the same
    /// reason `extendToCover` is a parameter here: the two gestures that can
    /// provoke a refusal (double-click-to-create past the end, and m25-f-3's
    /// edge drag) both submit through this ONE call, so they cannot end up with
    /// one warned path and one silent one. The other four callers pass an empty
    /// set and the store answers nil, so nothing changes for them.
    private func commit(extendToCover: Set<UUID> = []) {
        onEngage()
        if let refusal = onCommit(model.buildSubmission(), extendToCover) {
            flashAutoExtendNotice(refusal)
        }
    }

    // MARK: - Clipboard (m23-ek-3)

    /// Runs one clipboard operation against this roll's notes. The ONE body both
    /// the Edit menu (via `clipboardNonce`) and the roll's own context menu call,
    /// so the two routes cannot become two policies.
    private func applyClipboardRequest(_ verb: ClipboardVerb) {
        switch verb {
        case .copy:
            // THE ROLL'S OWN GUARD, not the menu's disabled state. That state is
            // resolved from `noteSelection.hasSelection`, reported on a
            // transition; this is the live selection at the instant of the
            // click. If they disagree, the roll wins and the menu is a no-op —
            // the `deleteNonce` handler's rule, verbatim.
            guard !model.selection.isEmpty else { return }
            onCopyNotes(selectedNotes())
        case .cut:
            guard !model.selection.isEmpty else { return }
            // m23-al R9 — THE CLIPBOARD FUNNEL. A cut or a paste is the user
            // EDITING inside this roll, exactly as the context-menu delete is
            // (which engages through R6's `commit()`), so the roll claims
            // ⌘+/⌘−/⌘0 the same way.
            //
            // ⚠️ COPY DELIBERATELY DOES NOT ENGAGE, and that is the R6 rule
            // rather than an omission: every funnel R1–R8 is a gesture that
            // CHANGES something, and R6's whole safety argument is that its
            // callers are user EDITS. Copy mutates nothing at all — it is the
            // reason `edit.copy` is not even a wire verb — so engaging on it
            // would let a pure read silently re-point the zoom keys.
            onEngage()   // m23-al R9 — clipboard cut
            // ⚠️ CLIPBOARD-ON-SUCCESS. `onCutNotes` performs the store edit and
            // reports whether it took; the local draft follows only then, so a
            // refused cut leaves the roll showing exactly what the project holds
            // AND leaves the clipboard untouched.
            //
            // The draft change is `deleteSelection()` — the DELETE key path's own
            // mutation, never a parallel one — so cut and delete can never
            // disagree about what "remove the selection" means here.
            //
            // ⚠️⚠️ NAMED CONSEQUENCE, NOT AN OVERSIGHT: A NOTE CUT **DOES**
            // COALESCE, WHERE A NOTE PASTE DOES NOT. Cut is defined as "the
            // delete that already ships, plus a clipboard write", so it commits
            // through `setClipNotes`, which journals under `clip.notes:<id>` —
            // and the undo journal folds same-key edits inside 800 ms. A cut
            // landing that soon after a note edit on this clip therefore FOLDS
            // INTO IT, and one ⌘Z reverses both. That is exactly the trap
            // `ProjectStore.pasteNotes` was added to close on the paste side, and
            // it deliberately survives here for one reason: DELETE has the same
            // property today, and m23-cf's rule is that a menu route is a SECOND
            // ROUTE to one operation, never a second policy — a cut and a delete
            // that removed identically but undid differently would be exactly
            // that. THE ONE-LINE REMEDY IF THIS IS EVER JUDGED WRONG: give
            // `onCutNotes` a `pasteNotes`-shaped uncoalesced store call. Do not
            // rediscover this a third time; it is a product call, not a bug.
            if onCutNotes(selectedNotes(), model.draft.filter { !model.selection.contains($0.id) }) {
                model.deleteSelection()
            }
        case .paste:
            let payload = clipboardNotes
            guard !payload.isEmpty else { return }
            // m25-f-2 — WHERE IT LANDS IS `PasteAnchorPolicy.resolveNotePaste`'s
            // decision, not this view's. Three rules: on the playhead when the
            // transport is inside this clip, else ABOVE the notes it was copied
            // from when those are still here, else at the start of the visible
            // area. Read that function's banner before changing anything here.
            let landing = PasteAnchorPolicy.resolveNotePaste(
                payload: payload,
                playheadProjectBeat: positionBeats,
                clipStartBeat: clip.startBeat,
                clipLengthBeats: clip.lengthBeats,
                // THE DRAFT, not the store's notes: a paste must sit above what
                // the user can SEE, and an uncommitted edit is on screen.
                existingNotes: model.draft,
                visibleStartLocalBeat: model.beat(forX: gridScrollX),
                visiblePitches: visiblePitchWindow)
            // ⚠️ SNAP THE ANCHOR **ONCE**, THEN TRANSLATE RIGIDLY. Snapping each
            // pasted note's absolute start instead WELDS notes sitting at
            // different sub-grid phases — a swung or triplet figure pasted onto a
            // 1/16 grid would come out straight, silently. That is the m23-g2
            // defect verbatim: snapping is a property of the GESTURE, not of each
            // element. With snap off, `model.snap` passes through (floored at 0),
            // so this same path is correct there too.
            //
            // ⚠️⚠️ AND `landing.snap` DECIDES WHICH WAY, WHICH IS NOT A BOOL.
            // An above-the-source paste re-uses the payload's OWN start, so
            // snapping it at all would drag a swung figure onto the grid — the
            // same weld, one level up, against an anchor that was never the
            // user's to move. A visible-area paste must snap UP: `model.snap`
            // rounds to NEAREST, which at `.bar` in 4/4 rounds the viewport's
            // leading edge BACKWARD by up to 2 beats and puts the group off the
            // left of the screen — defeating the one branch whose whole purpose
            // is that the user can see it.
            let anchor: Double
            switch landing.snap {
            case .nearest: anchor = model.snap(beat: landing.localBeat, resolution: effectiveSnap)
            case .upward: anchor = model.snapUp(beat: landing.localBeat, resolution: effectiveSnap)
            case .none: anchor = max(0, landing.localBeat)
            }
            let pasted = PasteAnchorPolicy.translatedNotes(
                payload, toAnchor: anchor, pitchOffset: landing.pitchOffset)
            guard !pasted.isEmpty else { return }
            onEngage()   // m23-al R9 — clipboard paste
            // Canonically ordered so the store's own ordering matches and
            // `needsReseed` stays false — which is what keeps the selection below
            // from being wiped by the reseed the commit triggers.
            model.draft = MIDINote.canonicallyOrdered(model.draft + pasted)
            // m25-f-2 — THE NOTES THIS GESTURE PLACED. Named once, used twice,
            // and deliberately NOT read back off `model.selection` at the call
            // below: the store is being told which notes may move the clip's
            // trailing edge, and "what this paste placed" is the invariant that
            // has to hold there — not "what happens to be selected", which the
            // next line makes equal only incidentally.
            let pastedIDs = Set(pasted.map(\.id))
            // The pasted notes become the selection, so the user can drag them
            // immediately (the double-tap-add precedent, `model.selectOnly`).
            model.selection = pastedIDs
            // ⚠️ `extendToCover:` IS NOT A `commit(` CALL. The paste stays on
            // the UNCOALESCED `pasteNotes` route (see `onPasteNotes`' banner);
            // it merely gained the same auto-extend rule `commit(extendToCover:)`
            // already applies to note creation and note drags. The R6
            // false-engage guard in `EditorSurfaceOwnershipSiteTests` counts
            // `commit(` occurrences in this file — this line must not become one.
            //
            // m25-a-2 — the SECOND call site of the refusal, and the one that is
            // easy to forget: a paste landing past a blocked edge is exactly as
            // silent as a double-click was.
            if let refusal = onPasteNotes(model.buildSubmission(), pastedIDs) {
                flashAutoExtendNotice(refusal)
            }
        }
    }

    /// The draft notes the user has selected, in draft order.
    private func selectedNotes() -> [MIDINote] {
        model.draft.filter { model.selection.contains($0.id) }
    }

    /// The pitch rows currently ON SCREEN, or nil before the editor has been
    /// measured (m25-f-2).
    ///
    /// It bounds the paste nudge: the user's reason for wanting the group offset
    /// at all is that they can *"immediately capture them with mouse"*, so a
    /// nudge that pushed the copy off the top of the view would defeat the whole
    /// feature. `pitch(forY:)` is the model's own affine mapping (row 0 is pitch
    /// 127, y grows as pitch falls), consumed rather than re-derived — so the
    /// window can never disagree with the rows being drawn.
    ///
    /// ⚠️ `editorViewportHeight` is the SCROLLER's height and is documented on
    /// `minimapOverlay` as overstating the visible pitch by the ~18 pt frozen
    /// scrub strip. That error is in the safe direction here too: the window is
    /// never claimed SMALLER than it is, so a nudge this bounds is never pushed
    /// off screen by the discrepancy — at worst a row at the very top edge is
    /// considered visible when it is under the strip.
    private var visiblePitchWindow: ClosedRange<Int>? {
        guard editorViewportHeight > 0 else { return nil }
        let top = model.pitch(forY: gridScrollY)
        let bottom = model.pitch(forY: gridScrollY + editorViewportHeight)
        guard bottom <= top else { return nil }
        return bottom...top
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pianokeys")
                .font(.system(size: 12))
                .foregroundStyle(noteColor)
            Text(clip.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            if clip.isAIGenerated {
                Text("AI")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(DAWTheme.ai)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.ai.opacity(0.6), lineWidth: 1))
            }

            Spacer()

            modeToggle
                .explainable(.panelDensity)   // shared density id (ex-b)
            // NOTES | STEPS (m23-cq-1) — which editor this pane shows. In BOTH
            // densities: choosing the drum grid over the piano roll is the
            // beginner's move, not Pro chrome.
            editorModeToggle
                .explainable(.stepSequencerMode)
            if editorMode == .steps {
                if mode == .pro {
                    stepResolutionPicker
                        .explainable(.stepSequencerStep)
                }
            } else {
                // Zoom cluster (m21-c) — shown in BOTH densities (zoom is view
                // navigation, not Pro edit chrome — the arrange m17-b rationale).
                zoomCluster
                    .explainable(.pianoRollZoom)
                if mode == .pro {
                    snapPicker
                        .explainable(.pianoRollSnap)
                }
            }
            quantizeChip
                .explainable(.quantize)
            humanizeChip
            barOpsCluster
                .explainable(.pianoRollBarOps)
            if editorMode == .notes {
                controllerLaneSummaryChip
            }
            maximizeToggle
                .explainable(.pianoRollMaximize)
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Passive Simple-density chip announcing the clip's controller lanes when it
    /// has any (m16-b4, the m15-c master-lane Pro-only precedent): data is never
    /// hidden, but EDITING controllers is a Pro surface — the full strip appears in
    /// Pro. NOT a button in v1 (no earned accent, Rule 3). Absent in Pro (the strip
    /// is shown instead) and when the clip has no lanes.
    @ViewBuilder
    private var controllerLaneSummaryChip: some View {
        if mode == .simple,
           let summary = ControllerStripModel.laneCountSummary(count: clip.controllerLanes.count) {
            HStack(spacing: 4) {
                Image(systemName: "dial.min")
                    .font(.system(size: 9, weight: .semibold))
                Text(summary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
            .help("This part has controller data (mod wheel, sustain, pitch bend). Switch to Pro to edit it.")
        }
    }

    // MARK: - Bar ops (insert / delete a measure, beta m10-h)

    /// Clip-local start beat of the target bar (under the playhead, else bar 0).
    private var targetBarStart: Double {
        PianoRollBarOps.targetBarStartBeat(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// One-based bar number the buttons act on — the SF Mono readout.
    private var targetBarNumber: Int {
        PianoRollBarOps.targetBarNumber(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// The readout's DRAWN string, composed at its one home in `DAWAppKit`
    /// (m23-t) so it is reachable from `Tests/` — `DAWApp` has no test target.
    private var barReadoutText: String {
        PianoRollBarOps.barReadoutLabel(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// Delete is off when it would collapse the clip below one bar (invalid → off).
    private var canDeleteBar: Bool {
        PianoRollBarOps.canDeleteBar(lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// The plain-language reason the delete-bar button can't act (≤ 1 bar left).
    private static let deleteBarBlockedReason =
        "This part is only one bar long — add a bar before deleting one."

    /// A compact glass cluster in the header: the target bar readout + insert/delete
    /// buttons (v1 acts on the bar under the playhead, or the first bar when the
    /// transport is elsewhere). Shown in BOTH densities — inserting/removing a
    /// measure is a structural edit a beginner reaches for, not Pro-only chrome.
    /// One bar = `beatsPerBar` beats (meter-aware). Dark glass + hairline, the
    /// snap-picker idiom; the +/− glyphs are neutral chrome (Rule 3 — an accent is
    /// earned by state, not by inviting a click). The delete button never goes
    /// dead (m21-c discoverability): when it can't act it stays dim but a press
    /// explains WHY inline (the m17-c refusal-bubble idiom) instead of silently
    /// swallowing the click — a tooltip alone proved undiscoverable.
    ///
    /// **The readout is an OPERAND, never a position (m23-t).** It used to draw
    /// in `DAWTheme.playback` under the comment "cyan = position readout", which
    /// contradicted `targetBarNumber`'s own doc one screen up ("the bar number
    /// the buttons act on"), the cluster's tooltips ("at bar n"), the explain
    /// card ("at the marked spot") — and Rule 3, invoked two lines above for the
    /// very glyphs beside it. With the transport four bars outside the clip the
    /// header drew a cyan `BAR 1`: the transport was nowhere near bar 1, and the
    /// accent said it was. Cyan is refused here for the same reason this view's
    /// Middle C marker refuses it (docs/DESIGN-LANGUAGE.md, piano-roll entry):
    /// **cyan in this very view is the transport playhead.**
    ///
    /// The ink is `textDim`, and neither of the cluster's own two tokens.
    /// `barOpButton` draws `enabled ? textPrimary : textFaint` — BOTH are button
    /// inks here, so either would make the readout read as a third button, and
    /// `textFaint` additionally MEANS "can't act right now" inside this cluster
    /// (and at 4.2–4.8:1 is the decorative floor, under Rule 5's 4.5:1 for a
    /// label). `textDim` is the caption tier and is exactly what the sibling
    /// readout in this same header uses — `zoomCluster`'s percent, same 9 pt
    /// medium SF Mono. The face stays monospaced: SF Mono means "numeric
    /// readout" in this app and this is one.
    ///
    /// The two clusters still do not collide: zoom is a true stepper
    /// (`[−][100%][+]`, no dividers, uniformly `textDim`), this one is
    /// `[BAR n] │ [+] │ [−]` — readout first, hairline dividers, brighter
    /// glyphs. Anatomy and ink distribution both differ, so `BAR n` beside +/−
    /// does not read as "nudge the number".
    private var barOpsCluster: some View {
        HStack(spacing: 0) {
            // Reported THROUGH the arguments, never beside them (the m23-p2
            // law): `reportedBarOpsText`/`reportedBarOpsInk` publish what they
            // RETURN, so the value handed to `Text`/`.foregroundStyle` IS the
            // value `debug.pianoRollBarOps` reports. A reporter in a sibling
            // `.onChange` survived a literal colour mutation twice.
            //
            // Intrinsically sized on purpose: the number is DATA (clip length ×
            // playhead), not a closed vocabulary, so no `.frame(width:)` and no
            // `.fixedSize` — a pin without the width overflows and gets cut
            // mid-glyph by the cluster's `clipShape`, with no ellipsis.
            Text(reportedBarOpsText(barReadoutText, role: Self.barReadoutRole))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(reportedBarOpsInk(DAWTheme.textDim, role: Self.barReadoutRole))
                .padding(.horizontal, 7)
            barOpsDivider
            barOpButton(system: "plus", enabled: true,
                        help: "Insert an empty bar at bar \(targetBarNumber), pushing later notes right") {
                insertBar()
            }
            barOpsDivider
            barOpButton(system: "minus", enabled: canDeleteBar,
                        help: canDeleteBar
                            ? "Delete bar \(targetBarNumber) and pull the rest of the part back to close the gap"
                            : Self.deleteBarBlockedReason) {
                if canDeleteBar {
                    deleteBar()
                } else {
                    flashBarOpsNotice(Self.deleteBarBlockedReason)
                }
            }
        }
        .frame(height: 22)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) { barOpsNoticeBubble }
    }

    private var barOpsDivider: some View {
        Rectangle().fill(DAWTheme.hairline).frame(width: 1, height: 14)
    }

    // MARK: Bar-ops readout probe (m23-t)

    /// The one role this cluster reports. A role that never publishes both
    /// halves is the signature of a call site replaced by a literal, which
    /// `debug.pianoRollBarOps` reports as null and the gate FAILS on — never
    /// skips.
    static let barReadoutRole = "barReadout"

    /// Publishes the string and RETURNS it, so what `Text` draws is what the
    /// probe reports (the `EffectEditorOverlay.reportedFont` shape).
    private func reportedBarOpsText(_ string: String, role: String) -> String {
        onBarOpsStyle(role, string, nil)
        return string
    }

    /// Publishes the ink and RETURNS it, so the colour handed to
    /// `.foregroundStyle` IS the reported colour.
    ///
    /// Hands over the `Color` itself and lets the ledger resolve it: this runs
    /// ~29×/s during playback (measured: one call per body, and the body ran 59
    /// times in 2.007 s), and `DAWTheme.hexString` is an
    /// `NSColor` bridge plus a `String(format:)` — a per-frame allocation in
    /// drawing code. Resolution still happens through `NSColor` on the far side,
    /// never as an echoed token name: a probe naming the token it INTENDED
    /// agrees with itself while the view draws something else.
    private func reportedBarOpsInk(_ ink: Color, role: String) -> Color {
        onBarOpsStyle(role, nil, ink)
        return ink
    }

    /// Where the bar-ops cluster's DRAWN text and ink land (m23-t).
    ///
    /// Deliberately OUTSIDE Observation — the `EffectHonestyStyleLedger` shape,
    /// and for the same reason: the view reports from inside its own
    /// `Text`/`.foregroundStyle` ARGUMENTS, which run during `body`, so the
    /// write must not invalidate the view making it. An `@Observable` here is a
    /// hang, not a compile error. Read only by `debug.pianoRollBarOps`.
    ///
    /// The two halves arrive as separate calls (a string argument and a colour
    /// argument), so an entry can be half-filled for one frame; a PERMANENTLY
    /// half-filled entry is what the gate fails on.
    ///
    /// The ink arrives as a `Color` and is resolved to sRGB hex HERE, once per
    /// CHANGE. The view reports on every `body`, which during playback is ~29
    /// times a second (MEASURED via `ticks`, which counts REPORTS at two per
    /// body: 118 reports = 59 bodies in 2.007 s), and drawing code does not get to
    /// allocate per frame — so the `NSColor` round-trip sits behind a
    /// last-value memo. Resolving in the caller instead, or hoisting the hex to
    /// a `static let`, both decouple the reported value from the DRAWN one, and
    /// a decoupled reporter is exactly the defect the m23-p2 law names.
    @MainActor
    final class BarOpsStyleLedger {
        private(set) var entries: [String: (text: String?, ink: String?)] = [:]

        /// How many times the view has reported. One per reporter CALL, so two
        /// per `body` evaluation of the cluster. Counted, never reasoned about:
        /// this is the instrument that settled whether the cluster redraws on
        /// every transport tick. It does: 0 reports idle over 2 s, 118 over
        /// 2.007 s playing — which is 59 BODIES, ~29/s, not 118 redraws.
        private(set) var ticks = 0

        /// How many of those reports actually cost an `NSColor` resolution. Must
        /// stay FLAT while `ticks` climbs; that difference is the memo working,
        /// and it is the only observable proof that it does.
        private(set) var inkResolutions = 0

        private var lastInk: [String: Color] = [:]

        func record(role: String, text: String?, ink: Color?) {
            ticks += 1
            var entry = entries[role] ?? (text: nil, ink: nil)
            if let text { entry.text = text }
            if let ink, lastInk[role] != ink {
                lastInk[role] = ink
                entry.ink = DAWTheme.hexString(ink)
                inkResolutions += 1
            }
            entries[role] = entry
        }

        /// Drops the memo along with the entries — otherwise a reset would leave
        /// `lastInk` matching, the next report would skip resolution, and the
        /// role would read back with a permanently null ink.
        func clear() {
            entries.removeAll()
            lastInk.removeAll()
            ticks = 0
            inkResolutions = 0
        }
    }

    /// A press on a can't-act bar op explains itself here (m21-c): the m17-c
    /// edit-refusal bubble — amber (nothing happened, nothing destroyed), SF Pro
    /// prose, soft warning glow — hung under the cluster, auto-clearing.
    @ViewBuilder
    private var barOpsNoticeBubble: some View {
        if let barOpsNotice {
            Text(barOpsNotice)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DAWTheme.record)
                .multilineTextAlignment(.trailing)
                .frame(width: 240, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(DAWTheme.record.opacity(0.6), lineWidth: 1))
                .glow(DAWTheme.record, radius: 3, intensity: 0.3)
                .offset(y: 26)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// The AUTO-EXTEND refusal chip (m25-a-2): the store's message VERBATIM in
    /// the app's shared `ArrangeRefusalBubble` — amber (the edit didn't fully
    /// happen, nothing was destroyed), SF Pro prose, soft warning glow,
    /// transient, hit-test-through.
    ///
    /// ⭐ **THE SHARED COMPONENT, NOT A THIRD COPY OF IT.** Its own doc is *"ONE
    /// component, two anchors… the callers own only the placement"*, and this is
    /// the third anchor. `barOpsNoticeBubble` above is deliberately left as it
    /// is — it predates the shared component and is tuned trailing-aligned at
    /// 240 pt for the header cluster it hangs under; converting it here would be
    /// a visual change outside this item's scope, and is filed rather than
    /// smuggled in.
    ///
    /// **ANCHORED OVER THE GRID, NOT UNDER THE HEADER, and the difference is the
    /// rule**: a refusal bubble hangs on the thing it is about. The bar-ops
    /// notice explains a BUTTON, so it hangs at that button; this one explains a
    /// NOTE the user just placed, so it stands over the note grid. It clears the
    /// scrub ruler band so it never covers the transport handle.
    ///
    /// ⚠️ **ANCHORED `.topLeading` PAST `keyboardWidth`, NOT CENTRED, AND THAT IS
    /// THE m25-f-5 LESSON APPLIED RATHER THAN RE-LEARNED.** A centred anchor
    /// would put this bubble at `(viewportWidth − 300) / 2`, which is arithmetic
    /// over a width this view has already been burned by (a `ZStack` once took
    /// the CONTENT width here and centred the overflow, painting across the
    /// gutter). Every sibling overlay on the editor — `scrubStrip`,
    /// `offClipCueBand` — clears the ivory keyboard gutter by starting past
    /// `keyboardWidth` instead, so this one does too: the clearance is
    /// structural, not a sum that can drift when the viewport changes.
    @ViewBuilder
    private var autoExtendNoticeBubble: some View {
        if let autoExtendNotice {
            ArrangeRefusalBubble(message: autoExtendNotice)
                .padding(.leading, Self.keyboardWidth + 8)
                .padding(.top, Self.scrubStripHeight + 8)
                .transition(.opacity)
        }
    }

    /// Shows the auto-extend refusal for a few seconds, then fades it.
    ///
    /// The `flashBarOpsNotice` shape verbatim — cancel the standing task first,
    /// so a second refusal restarts the clock instead of being erased by the
    /// first one's timer. Six seconds rather than the bar-ops three: this
    /// message is two sentences and names a remedy, and the arrange's own
    /// refusal (`AppModel.presentArrangeRefusal`) already stands for six.
    private func flashAutoExtendNotice(_ message: String) {
        autoExtendNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { autoExtendNotice = message }
        autoExtendNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { autoExtendNotice = nil }
        }
    }

    /// Shows the inline bar-ops reason for a few seconds, then fades it.
    private func flashBarOpsNotice(_ message: String) {
        barOpsNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { barOpsNotice = message }
        barOpsNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { barOpsNotice = nil }
        }
    }

    private func barOpButton(system: String, enabled: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? DAWTheme.textPrimary : DAWTheme.textFaint)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        // Deliberately NOT `.disabled` (m21-c): the action itself refuses and
        // explains when it can't act, so the press is never silently dead; the
        // dim `textFaint` glyph still reads as "not available right now".
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Zoom (m21-c)

    /// The header's compact zoom cluster — the arrange toolbar's magnifier
    /// cluster (m17-b) at header-chip scale: −/+ steps around an SF Mono
    /// percent readout, neutral chrome (zoom is navigation, not an active
    /// state — Rule 3). Every driver mutates the ONE persisted
    /// `panelLayout.pianoRollPPB` slot (buttons here, pinch on the grid, and
    /// the View-menu ⌘+/⌘−/⌘0 while the editor is focused via the app router).
    ///
    /// ⭐ **m25-b-3 REACHED THESE BUTTONS WITHOUT EDITING THEM, AND THAT IS THE
    /// ARGUMENT FOR WHERE IT LIVES.** They still write nothing but the scale; the
    /// no-jump anchor rides on the slot's `onChange` (`repinZoomAnchor`), so the
    /// ± cluster, ⌘±, and the debug seam cannot drift apart. A stepper press has
    /// no pointer, so it anchors on the playhead when the roll is drawing one and
    /// on the viewport centre otherwise.
    private var zoomCluster: some View {
        HStack(spacing: 0) {
            // m23-al R5 — the roll's OWN zoom cluster. Pressing it is a gesture
            // inside the roll, so it claims the surface for the ⌘ keys as well;
            // that is what keeps the roll reachable under "last-engaged wins".
            zoomStepButton("minus.magnifyingglass", help: "Zoom the notes out (⌘− after you click in the editor)") {
                onEngage()
                layout.setPianoRollPPB(PianoRollZoom.zoomedOut(layout.pianoRollPPB))
            }
            Text(PianoRollZoom.percentLabel(pixelsPerBeat: layout.pianoRollPPB))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 34)
                .help("Editor zoom — ⌘0 resets to 100% after you click in the editor")
            zoomStepButton("plus.magnifyingglass", help: "Zoom the notes in (⌘+ after you click in the editor)") {
                onEngage()   // m23-al R5
                layout.setPianoRollPPB(PianoRollZoom.zoomedIn(layout.pianoRollPPB))
            }
        }
        .frame(height: 22)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func zoomStepButton(_ systemImage: String, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// ⭐⭐⭐ **THE NO-JUMP RULE (m25-b-3), AND THERE IS EXACTLY ONE OF IT.** Every
    /// zoom of this surface — the header ± cluster, the grid pinch, ⌘+/⌘−/⌘0
    /// through the app router, and `debug.panelLayout {pianoRollPPB}` — writes the
    /// ONE persisted `panelLayout.pianoRollPPB` slot, so the change itself is the
    /// only event all four share. Hanging the rule here is what makes a driver
    /// unable to forget it.
    ///
    /// ⚠️ **THAT IS A DELIBERATE DIVERGENCE FROM THE ARRANGE, WHICH THIS ADOPTS
    /// FROM.** `setArrangeZoom` is a per-driver entry point, and its rule holds
    /// only as long as every caller remembers to use it — a caller that writes
    /// `panelLayout.setArrangePPB` directly gets the jump back, silently. The roll
    /// has FOUR drivers and one of them (`debug.panelLayout`) is a generic slot
    /// setter that could never be routed through a zoom-specific entry point
    /// without forking it. Same rule, one hop later, and every writer covered.
    ///
    /// **The ordering is load-bearing and is the arrange's:** the compensating
    /// offset is computed from the OLD scale, and the anchor's screen x is
    /// measured in the OLD scale too (`playheadLineX(atPPB:)` — see the warning on
    /// that overload, which is the one real bug in this item's blast radius).
    ///
    /// **Anchor, per driver:**
    /// - **Pinch → the POINTER.** `zoomAnchorBase` is captured on the first tick
    ///   from `MagnifyGesture.Value.startLocation` and the whole gesture measures
    ///   off it. The pointer is the thing the user is looking at, and the arrange
    ///   agrees (`TimelineLanesView:1000` feeds `startLocation.x` into
    ///   `PinchState`).
    /// - **Everything else → the PLAYHEAD when there is a line, else the viewport
    ///   centre** (`PianoRollZoom.anchorScreenX`, which delegates the in-frame test
    ///   to `ArrangeZoom` and adds the roll's m23-c1 off-clip case). A stepper
    ///   press and a ⌘+ have no pointer to speak of; the playhead is the one point
    ///   on this surface the eye is already on.
    ///
    /// ⭐ **THE PLAYHEAD ANCHOR ALSO SETTLES FOLLOW-THE-PLAYHEAD PRECEDENCE
    /// WITHOUT A TIE-BREAK — WHEN THE PLAYHEAD IS THE ANCHOR.** Holding its
    /// screen x is exactly the condition under which `FollowPlayhead.pageOffset`
    /// returns nil, so there is no competing scroll to break a tie about — the two
    /// rules agree by construction instead of fighting.
    ///
    /// ⚠️ **The qualifier is real, so do not drop it.** When the anchor is the
    /// CENTRE instead, one reachable case has two writers for a single tick: the
    /// playhead inside this clip but scrolled OUT of the viewport (so
    /// `anchorScreenX` falls back to the centre) while playing and unsuspended, on
    /// the tick that crosses the follow margin. `followDrives` keys off the clip,
    /// not the viewport, so follow is still driving there. Off-clip is NOT that
    /// case — `playheadLineX` is nil, and follow issues nothing at all. Both
    /// writers recompute from the OBSERVED offset rather than integrating, so the
    /// last write wins and the next tick agrees; it is a one-tick overlap, not a
    /// fight. An unqualified version of this sentence is the sort that put the
    /// wrong claim in `PanelLayoutModel` and DESIGN-LANGUAGE in the first place.
    ///
    /// And the offset is delivered
    /// through `scrollExternally` (the roll's one programmatic scroll seam, m23-c2)
    /// like the minimap jump and the edge drag, but **a zoom is NOT read as a
    /// manual scroll**: the report that carries it also carries a changed
    /// `contentWidth` (the grid is `beats · ppb`), and the detector re-baselines on
    /// a geometry change instead of suspending — its own doc names *zoom* in that
    /// list (`FollowPlayheadModel`, "a resize / zoom / edit, NOT a user scroll").
    ///
    /// ⚠️ **RESIDUAL, MEASURED NOWHERE AND THEREFORE STATED:** if the scroller
    /// clamps itself on the rescale BEFORE this scroll lands, the detector sees two
    /// reports — the first absorbed by the geometry change, the second (same
    /// geometry, different offset) read as the user, suspending follow. It costs a
    /// PAUSED chip and one click, never data, and the arrange carries the identical
    /// exposure today through `applyArrangeHScroll`. Curing it means teaching
    /// `reportOffset` to hold an in-flight expectation across a geometry change,
    /// which changes shipped behaviour on BOTH surfaces and is not this item's.
    private func repinZoomAnchor(oldPPB: CGFloat, newPPB: CGFloat) {
        // The `initial: true` call arrives with old == new, and so does a clamped
        // write at either end of the ladder: no scale change, nothing to re-pin.
        // A zero viewport is a view that has not been laid out yet — there is no
        // anchor to hold and `bandViewportWidth / 2` would be a fake one.
        guard abs(newPPB - oldPPB) > 0.0001, bandViewportWidth > 0 else { return }
        let base = zoomAnchorBase ?? ZoomAnchorBase(
            ppb: oldPPB,
            offset: gridScrollX,
            anchorScreenX: PianoRollZoom.anchorScreenX(
                // ⚠️ AT THE **OLD** SCALE. `model.pixelsPerBeat` is already the new
                // one by the time this runs.
                playheadContentX: playheadLineX(atPPB: oldPPB),
                offset: gridScrollX, viewportWidth: bandViewportWidth))
        follow.scrollExternally(to: ArrangeZoom.offsetPreservingAnchor(
            oldPPB: base.ppb, newPPB: newPPB,
            oldOffset: base.offset, anchorScreenX: base.anchorScreenX))
    }

    /// The live pinch (m21-c, anchored by m25-b-3): magnification is cumulative,
    /// so every tick rescales off the gesture-START scale — which is now the same
    /// `zoomAnchorBase` the anchor is measured from, one memo instead of two.
    ///
    /// ⚠️ **IT WRITES THE SCALE AND NOTHING ELSE.** The offset is `repinZoomAnchor`'s
    /// to issue, for both drivers, so there is exactly one writer of the roll's
    /// scroll offset per zoom and no ordering question about which of two callers
    /// lands last. (An earlier sketch had the pinch call `scrollExternally` itself
    /// and let the funnel skip while a pinch was live; the skip would have had to
    /// out-race the gesture's own `onEnded`, which nothing guarantees.)
    ///
    /// ⚠️ **`startLocation` IS A CONTENT-SPACE POINT**, because this gesture is
    /// attached to the grid Canvas INSIDE the horizontal scroller — the same space
    /// `gridDrag` feeds straight into `model.hitTest` with no offset term. Hence
    /// `- gridScrollX` to reach the screen x that must stay put. It is also frozen
    /// at gesture start, so it means that beat only at the START scale, which is
    /// the second reason the base is captured once rather than re-derived.
    ///
    /// ⚠️ Historical note kept because it was wrong twice: this used to say an
    /// anchor re-pin "needed an AppKit bridge" (corrected m23-c2 — the programmatic
    /// scroll is plain SwiftUI), and then that it "remains unbuilt" because landing
    /// mid-gesture against rescaling content is hard. It is built, and what made it
    /// tractable was not a bridge but a fixed anchor: the arrange's rule, unchanged.
    private var gridPinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                onEngage()   // m23-al R3 — pinch-zoom the roll
                if zoomAnchorBase == nil {
                    zoomAnchorBase = ZoomAnchorBase(
                        ppb: layout.pianoRollPPB, offset: gridScrollX,
                        anchorScreenX: value.startLocation.x - gridScrollX)
                }
                guard let base = zoomAnchorBase else { return }
                layout.setPianoRollPPB(PianoRollZoom.clamp(base.ppb * value.magnification))
            }
            // ⚠️ The last tick's ppb change may not have been delivered to the
            // funnel yet when this fires. If it lands after, that ONE tick is
            // anchored on the playhead/centre instead of the pointer — bounded by
            // a single magnification step (a fraction of a point at 60 Hz), and
            // self-limiting because the next gesture captures a fresh base. A
            // state machine to close it would cost more than the error it removes.
            //
            // ⚠️ INHERITED, NOT NEW: `if zoomAnchorBase == nil` means a base left
            // behind by a DROPPED `onEnded` is never refreshed, so the next
            // pinch's first tick would rescale from the stale start scale
            // (`base.ppb * 1.0`) and jump. The `pinchStartPPB` this replaced had
            // the identical shape, and m25-r's teardown notes say plainly that
            // `onEnded` is not guaranteed. Switching clips cannot carry one over
            // (`.id(clip.id)` rebuilds this view and its `@State`). Left as-is
            // deliberately: the fix is a gesture-generation token, which is
            // m25-r's shape of problem, not this item's.
            .onEnded { _ in zoomAnchorBase = nil }
    }

    /// Inserts one empty bar at the target bar start, then reseeds the edit model
    /// from the updated clip (the store closed/opened the gap — the model must
    /// re-read, not keep its stale draft).
    private func insertBar() {
        if let updated = onInsertTimeRange(targetBarStart, Double(beatsPerBar)) {
            model.load(notes: updated.notes ?? [], clipLengthBeats: updated.lengthBeats)
            // Clip-local bar edits leave controller lanes untouched (design-m16b
            // §14 A4) but change the clip length — reseed so the strip's drawn
            // width tracks.
            controllerModel.load(lanes: updated.controllerLanes, clipLengthBeats: updated.lengthBeats)
        }
    }

    /// Deletes the target bar and closes the gap, then reseeds the edit model.
    private func deleteBar() {
        if let updated = onDeleteTimeRange(targetBarStart, Double(beatsPerBar)) {
            model.load(notes: updated.notes ?? [], clipLengthBeats: updated.lengthBeats)
            controllerModel.load(lanes: updated.controllerLanes, clipLengthBeats: updated.lengthBeats)
        }
    }

    /// Opens the Quantize & Groove panel for this clip (m11-a). Neutral create-
    /// chrome (Rule 3 — `textPrimary`, no earned accent at rest); the snap-picker
    /// chip idiom, never a stock control.
    private var quantizeChip: some View {
        Button(action: onOpenQuantize) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    .font(.system(size: 9, weight: .semibold))
                Text("QUANTIZE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Tighten this part's timing to a grid, or apply a groove")
    }

    /// Opens the Humanize panel for this clip (m25-c) — the QUANTIZE chip's
    /// sibling and its inverse. Neutral create-chrome (Rule 3 — `textPrimary`, no
    /// earned accent at rest); the same chip idiom, never a stock control.
    ///
    /// Shown in BOTH densities, like QUANTIZE: this chip is the ONLY thing a
    /// human can click to reach `humanizeClipNotes` (the capability shipped with
    /// a wire command and an MCP tool and no UI at all), so hiding it behind Pro
    /// would leave the beginner exactly where m25-c found them.
    private var humanizeChip: some View {
        Button(action: onOpenHumanize) {
            HStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 9, weight: .semibold))
                Text("HUMANIZE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Loosen this part's timing and velocity so it sounds played, not programmed")
    }

    /// Simple / Pro segmented chip — the shared `SimpleProToggle` component bound
    /// to this panel's density (docs/DESIGN-LANGUAGE.md density modes).
    private var modeToggle: some View {
        SimpleProToggle(
            store: densityStore,
            panelID: Self.panelID,
            help: "Simple: add, move, delete on a beat grid. Pro: velocity, snap, resize."
        )
    }

    /// NOTES | STEPS — which editor the pane shows (m23-cq-1).
    ///
    /// The house segmented-chip idiom, active half cyan-lit: the same shape as
    /// the density chip beside it, the arrange S/M/L cluster and the automation
    /// VOL/PAN pair. Cyan is legal here for the reason it is legal there — the
    /// lit half is an ACTIVE state, not an invitation to click (Rule 3).
    ///
    /// A CHIP PAIR AND NOT A MENU, deliberately: there are exactly two editors,
    /// both worth naming on screen, and a beginner who has never seen a step
    /// sequencer will not go looking inside a menu for one.
    private var editorModeToggle: some View {
        HStack(spacing: 0) {
            ForEach(ClipEditorMode.allCases, id: \.self) { candidate in
                let active = editorMode == candidate
                Button {
                    stepSequencer.setMode(candidate)
                } label: {
                    Text(candidate.label.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textDim)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(active ? DAWTheme.playback.opacity(0.18) : Color.clear)
                }
                .buttonStyle(.plain)
                .help(candidate == .steps
                      ? "Step grid — click boxes to place drum hits"
                      : "Piano roll — draw and drag notes")
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .fixedSize()
    }

    /// STEP size menu (Pro only) — the step grid's column division. Styled like
    /// the snap picker beside it, and it reuses the SAME `SnapResolution`
    /// vocabulary minus `off`, which names the absence of the thing this surface
    /// is made of (`StepSequencerGeometry.pickableResolutions`).
    private var stepResolutionPicker: some View {
        Menu {
            ForEach(StepSequencerGeometry.pickableResolutions, id: \.self) { resolution in
                Button {
                    stepSequencer.setResolution(resolution)
                } label: {
                    if stepSequencer.pickedResolution == resolution {
                        Label(resolution.label, systemImage: "checkmark")
                    } else {
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text("STEP: \(effectiveStepResolution.label)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How finely each bar is divided into boxes")
    }

    /// Themed snap menu (Pro only) — styled like the input-device picker chip,
    /// never a stock gray control (docs/DESIGN-LANGUAGE.md rule 2).
    ///
    /// ⚠️⚠️ **THE CHIP READS THE EFFECTIVE GRID; THE CHECKMARK MARKS THE PICK
    /// (m25-ab).** These differ in exactly one situation — the app-level snap is
    /// OFF — and showing the pick there would leave this chip announcing
    /// "SNAP: 1/16" while nothing snaps. That is the same duplicated-promise defect
    /// the user reported, one degree quieter, and it would be introduced BY the fix
    /// for it. The checkmark still sits on the user's own choice because that
    /// choice is intact and returns the instant the app-level snap comes back
    /// (`SnapResolution.effective` never mutates it) — the `debug.arrangeDrop`
    /// `snap` vs `effectiveSnap` split, made visible.
    ///
    /// ⚠️⚠️ **TODO (m25-ab, NOT DONE HERE) — THIS CONTROL HAS NO SEAM, AND THAT IS
    /// WHY THE BUG WAS INVISIBLE TO EVERY GATE.** The arrange's snap picker is
    /// observable (`debug.arrangeDrop` echoes `snap` AND `effectiveSnap`, precisely
    /// so a caller CHECKS that a snap it asked for landed); this one echoes
    /// nothing, so no automated check in the tree could ever have compared the two
    /// surfaces' grids. `PianoRollSnapPolicySiteTests` pins the wiring at the
    /// SOURCE, which is the strongest instrument available without a seam — but it
    /// cannot observe a running app.
    ///
    /// The missing surface, named exactly so it can be built without re-deriving
    /// this: debug verb **`debug.pianoRollSnap`**, params `{snap?: <SnapResolution
    /// rawValue>}`, echoing `{snap, appSnap, effectiveSnap, density}` — the
    /// `debug.arrangeDrop` shape. It needs the picked resolution to leave this
    /// view's `@State` first (the `StepSequencerBridge` pattern: an app-held
    /// `@Observable`, which would also fix the reset-on-clip-switch defect noted at
    /// `snap`'s declaration). MCP tool name if it is ever surfaced there:
    /// **`piano_roll_snap`** — though the arrange precedent argues it should stay
    /// debug-tier, since a snap PICKER is UI state and not an agent capability.
    /// Deliberately NOT built in this diff: a new stateful component does not
    /// belong in the same change as the pure policy that removes a second home.
    private var snapPicker: some View {
        Menu {
            ForEach(SnapResolution.allCases, id: \.self) { resolution in
                Button {
                    snap = resolution
                } label: {
                    if snap == resolution {
                        Label(resolution.label, systemImage: "checkmark")
                    } else {
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text("SNAP: \(effectiveSnap.label)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Grid snap resolution")
    }

    /// MAXIMIZE / RESTORE (m25-b-1) — the mode that suspends the editor's 0.30–0.55
    /// height clamp and gives the pane the window, minus the fixed chrome and the
    /// arrange's pinned ruler strip.
    ///
    /// ⭐ **SIZED LIKE `closeButton`, DELIBERATELY.** The roll header already
    /// carries density, editor mode, zoom, snap, quantize, bar-ops and the
    /// controller chip inside a window whose floor is 1208 pt wide; m25-e shipped a
    /// ~104 pt toolbar addition on an unverified estimate and recorded that as a
    /// risk. A 22×22 icon square in the established `panelRaised` / corner-5
    /// grammar is the cheapest footprint the header has, and it sits immediately
    /// before CLOSE because "make it big / put it away" are the same family of
    /// pane-level action.
    ///
    /// ⭐ **TWO FACES, AND THE STATE IS READABLE AT A GLANCE** (Rule 3 — accent is
    /// earned by state, and maximized is an earned active state the user chose):
    /// neutral `textDim`-on-`panelRaised` at rest, `playback` cyan + fill + glow
    /// while maximized, with the glyph flipping outward/inward. Cyan, never violet
    /// — nothing here is AI-touched. The tooltip names the Escape exit in the
    /// maximized face, so the second way out is discoverable from the first.
    private var maximizeToggle: some View {
        let maximized = layout.editorMaximized
        return Button {
            // ⭐ m23-al R10 — THE MAXIMIZE FUNNEL (new at m25-b-1), and it is a
            // funnel rather than an exception for a reason worth stating: the
            // rule these sites obey is "a gesture that CHANGES something", which
            // R5 (the zoom cluster) already shows includes a VIEW change and not
            // only an edit — the excluded case is a pure READ, which is why COPY
            // is deliberately not a site. Maximizing changes the view, and it is
            // the strongest possible statement that the roll is where the user is
            // working, so ⌘+/⌘−/⌘0 must follow it here. Without this, maximizing
            // would leave the zoom keys aimed at an arrange that is now an 86 pt
            // ruler strip. (CLOSE is the counter-example that is NOT a site: it
            // ends the surface rather than claiming it.)
            onEngage()   // m23-al R10 — maximize toggle
            // Straight to the shared store, exactly as the zoom cluster writes
            // `pianoRollPPB`. The STATE is the funnel — this toggle and the Escape
            // route are two drivers of one persisted slot, and neither owns it.
            layout.setEditorMaximized(!maximized)
        } label: {
            Image(systemName: EditorMaximize.toggleSymbol(maximized: maximized))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(maximized ? DAWTheme.playback : DAWTheme.textDim)
                .frame(width: 22, height: 22)
                .background(maximized ? DAWTheme.playback.opacity(0.14) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .glow(DAWTheme.playback, radius: 5, intensity: maximized ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help(EditorMaximize.toggleHelp(maximized: maximized))
        .accessibilityLabel(EditorMaximize.toggleAccessibilityLabel(maximized: maximized))
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 22, height: 22)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Close piano roll")
    }

    // MARK: - Step sequencer band (m23-cq-1)

    /// The step grid, mounted in place of the note-editor stack. Thin over
    /// `StepSequencerBand`, which is thin over the headless geometry — this
    /// property's whole job is to hand it the LIVE derived values and to route
    /// its one gesture back into `applyStepToggle`.
    private var stepSequencerBand: some View {
        StepSequencerBand(
            geometry: stepGeometry,
            fills: StepSequencerEdit.fills(notes: model.draft, geometry: stepGeometry),
            noteColor: noteColor,
            // The transport line, mapped through the SAME headless playhead the
            // note grid uses — with the step grid's own beat scale (a column is
            // `stepBeats` wide), so the two editors put the playhead at the same
            // musical position.
            playheadX: PianoRollPlayhead.lineX(
                position: positionBeats, clipStartBeat: clip.startBeat,
                lengthBeats: clip.lengthBeats,
                pixelsPerBeat: stepGeometry.stepWidth / CGFloat(stepGeometry.stepBeats)),
            viewportWidth: panelWidth,
            bridge: stepSequencer,
            onToggle: applyStepToggle)
    }

    // MARK: - Editor (keyboard + grid), vertically scrolled together

    private var editor: some View {
        // m25-b-2 — the VERTICAL reader, added for the minimap's pitch-axis jump.
        // It necessarily spans both axes (the horizontal scroller is inside the
        // vertical one); what keeps that safe is WHERE its anchor is mounted, and
        // the argument is written out on `verticalJumpMarker`.
        ScrollViewReader { verticalProxy in
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                // m23-al R8 — the gutter keyboard. Its gesture lives in another
                // file (`KeyboardSidebar.swift:45`, attached `:127`), so the
                // engagement is added by WRAPPING the closure AT THIS CALL SITE
                // rather than by editing that view.
                // ⚠️ ONLY THIS ARGUMENT. `onAudition` is also called from
                // `applyGesture` (already covered by R1) and from teardown with an
                // empty pitch set — engaging on teardown would be a false engage.
                KeyboardSidebar(model: model, width: Self.keyboardWidth,
                                onAudition: { pitches, velocity in
                                    onEngage()
                                    onAudition(pitches, velocity)
                                })
                    // m25-b-2: the minimap's vertical-jump anchor. Mounted HERE —
                    // outside the horizontal scroller — on purpose; see
                    // `verticalJumpMarker`. An overlay, so the gutter's own layout
                    // is untouched and the marker can never change its width.
                    .overlay(alignment: .topLeading) { verticalJumpMarker }
                // The follow reader (m23-c2) wraps ONLY this horizontal scroller,
                // NOT the vertical one above it. A `ScrollViewReader` resolves
                // `scrollTo` against every scroll view inside ITS content, and
                // `anchor: .leading` carries a y of 0.5 — so a reader wrapping both
                // axes would centre the target VERTICALLY on every page turn and
                // silently yank the pitch view away from wherever the user left it.
                // Scoped here, the vertical scroller (and its
                // `.defaultScrollAnchor(.center)` opening position) is untouchable
                // by follow.
                ScrollViewReader { gridProxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    // The grid Canvas is its own struct with closure-free, tick-stable
                    // inputs (model ref + beatsPerBar + snap + color), so a transport
                    // tick — which re-evaluates this body — never re-invokes its draw
                    // closure: only the playhead overlay's offset moves (the arrange
                    // "offset a view, never a per-frame Canvas redraw" rule, enforced
                    // here by extraction rather than trusting Canvas diffing).
                    PianoRollGrid(model: model, beatsPerBar: beatsPerBar,
                                  snap: effectiveSnap, noteTintHex: noteTintHex)
                        // Extended to the viewport at wide windows (m18-f): the
                        // Canvas draws the extension correctly by construction —
                        // key rows + gridlines run the full width and the
                        // out-of-clip shade covers everything past the clip end.
                        .frame(width: gridDrawnWidth, height: model.contentHeight)
                        // Playhead above the grid, below floating chrome; full grid
                        // height so it reads at any vertical scroll position.
                        .overlay(alignment: .topLeading) { gridPlayhead }
                        // The rubber band (m23-ek-1), in the SAME content space
                        // the gesture reports its points in.
                        .overlay(alignment: .topLeading) { marqueeBandView }
                        // m25-g — the group compress/extend handle, same space.
                        .overlay(alignment: .topLeading) { groupScaleHandleView }
                        // m25-o — the ⌘ playhead-place preview, same space again.
                        .overlay(alignment: .topLeading) { playheadPlaceGhost }
                        .overlay(alignment: .topLeading) {
                            followMarker(Self.gridFollowMarkerID)
                        }
                        .background { gridScrollReader }
                        // Pointer affordances (docs/DESIGN-LANGUAGE.md): a note body
                        // grabs, its right-edge resize handle (Pro) resizes, empty
                        // grid keeps the arrow. Mirrors `gridDrag`'s hit routing.
                        // m25-o — the tracking area re-resolves on pointer
                        // MOVEMENT only, so a ⌘ press with the mouse still would
                        // never reach `gridCursor`. Bumping this token on the
                        // modifier's edge is what makes the affordance appear the
                        // instant ⌘ goes down and vanish the instant it comes up.
                        //
                        // m25-x — THE TOKEN IS THE CHORD ITSELF, not a ⌘ bit.
                        // `pointerModifiers` is what `gridCursor` reasons from,
                        // so making its raw value the token means the overlay
                        // re-asks on exactly the transitions that can change its
                        // answer and on no others. A `commandHeld ? 1 : 0` token
                        // would leave the cursor stale over the group-scale band
                        // when ⇧ went down alone — a cursor that promises an edge
                        // drag ⇧-click refuses, which is the defect this item is
                        // about, surviving in the one layer that caches.
                        .hoverCursor(resolve: gridCursor,
                                     refresh: pointerModifiers.rawValue)
                        // ⭐ m25-g — THE hover reader, and there is exactly one.
                        //
                        // ⚠️ `.local`, NOT the `.named(contentSpace)` idiom the
                        // timeline uses (`TempoLaneBand`, `TimelineLanesView`),
                        // and the difference is correctness rather than taste.
                        // A hover that disagrees with the press by even a scroll
                        // offset would draw the handle somewhere the click does
                        // not start it. Attached HERE, adjacent to
                        // `.gesture(gridDrag)`, `.local` is the same space
                        // `gridDrag` reports its points in — which is the grid's
                        // CONTENT space, and the evidence is shipped rather than
                        // asserted: `hoverCursor(resolve:)` resolves points at
                        // this same position in the chain straight through
                        // `model.hitTest`, and note hover cursors are correct.
                        // The timeline's named space is right for ITS readers,
                        // which hang off a different view than their gesture.
                        //
                        // NOT an extra gesture: `.onContinuousHover` is not in
                        // `rollGestureCountIsPinned`'s needle set, and it takes
                        // no press — hover and the drag coexist, exactly as the
                        // `hoverCursor` overlay already does.
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): hoverPoint = point
                            case .ended: hoverPoint = nil
                            @unknown default: hoverPoint = nil
                            }
                        }
                        // m25-o — the ⌘ monitor's LIFETIME is the hover, derived
                        // from the one reader above rather than from a second one.
                        // Off-surface there is nothing for ⌘ to mean here, and a
                        // global monitor that ran while the user typed ⌘S in
                        // another panel would be pure cost.
                        .onChange(of: hoverPoint != nil) { _, overGrid in
                            if overGrid { startFlagsMonitor() } else { stopFlagsMonitor() }
                        }
                        .gesture(gridDrag)
                        // Pinch-to-zoom (m21-c) — simultaneous so it never
                        // steals the drag/tap routing.
                        .simultaneousGesture(gridPinch)
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                onEngage()   // m23-al R4 — double-tap add note
                                let note = model.addNote(
                                    atBeat: model.beat(forX: value.location.x),
                                    pitch: model.pitch(forY: value.location.y),
                                    resolution: effectiveSnap
                                )
                                model.selectOnly(note.id)
                                // m25-a — the note the user just placed is the
                                // ONLY one allowed to grow the clip. Naming it
                                // (rather than asking for "fit the notes") is
                                // what stops a click at bar 2 from stretching
                                // the clip out to a latent note at bar 20.
                                commit(extendToCover: [note.id])
                            }
                        )
                        // m23-cf: THE ROLL'S FIRST CONTEXT MENU. Before this the
                        // only way to remove a note was the bare DELETE key, and
                        // a user reported that as "I cannot remove them" — with
                        // the key path dead for any reason the operation was
                        // simply unreachable.
                        //
                        // ⚠️ `.contentShape` IS LOAD-BEARING AND WAS MEASURED, NOT
                        // ADDED FOR TIDINESS. `PianoRollGrid`'s body is a `Canvas`,
                        // which draws but contributes NO hit-test region of its
                        // own. `.gesture` does not care — SwiftUI gestures resolve
                        // against the view's FRAME, which is why the grid's drag,
                        // pinch and double-tap all worked without one — but
                        // `.contextMenu` resolves against the AppKit hit region,
                        // so without this the right-click passes straight through
                        // and NO menu appears. MEASURED live on staging: identical
                        // right-clicks that opened the arrange clip's menu (a real
                        // `RoundedRectangle` fill, hence a real hit region) did
                        // nothing here. The arrange menu's silence about this is
                        // not a disagreement — it draws shapes and gets its region
                        // for free.
                        .contentShape(Rectangle())
                        .contextMenu { noteContextMenu }
                }
                .coordinateSpace(name: Self.gridScrollSpace)
                // Never animated — a page turn must not glide. The deferred
                // re-issue is the m17-b DURABILITY rule: a `scrollTo` that is not
                // re-issued on a fresh main-actor turn moves layout without
                // updating the scroller's internal position, and any later forced
                // re-render (`debug.captureUI`'s `cacheDisplay`, a resize) jumps
                // back to the stale value.
                .onChange(of: followNonce) { _, _ in
                    gridProxy.scrollTo(Self.gridFollowMarkerID, anchor: .leading)
                    Task { @MainActor in
                        gridProxy.scrollTo(Self.gridFollowMarkerID, anchor: .leading)
                    }
                }
                }
            }
            // m25-b-2: reads the CONTENT's position → the live vertical scroll
            // offset. A background on the scroll content, the `gridScrollReader`
            // shape one axis over.
            .background { editorVerticalScrollReader }
        }
        .defaultScrollAnchor(.center)   // open near middle C, full 0-127 scrollable
        .coordinateSpace(name: Self.editorVerticalScrollSpace)
        // m25-b-2 — the vertical half of a minimap jump. Same non-animated,
        // deferred-re-issue shape as the horizontal one above (m17-b durability):
        // a `scrollTo` not re-issued on a fresh main-actor turn moves layout
        // without durably updating the scroller's position.
        .onChange(of: verticalNonce) { _, _ in
            verticalProxy.scrollTo(Self.verticalJumpMarkerID, anchor: .top)
            Task { @MainActor in
                verticalProxy.scrollTo(Self.verticalJumpMarkerID, anchor: .top)
            }
        }
        // m25-b-2: the VIEWPORT height (outside the scroll content — this is the
        // visible box, not the 128-row stack).
        .background { editorHeightReader }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Off-clip cue (m23-c1): the complement of `gridPlayhead` — it draws
        // exactly when the line does not. Overlaid on the EDITOR (not on the
        // grid content) because it is viewport furniture, not a timeline
        // object; the pill clears the frozen scrub strip above it. Below the
        // scrub overlay so the scrub keeps the hit surface.
        .overlay(alignment: .topLeading) {
            offClipCueBand(topInset: Self.scrubStripHeight + 6)
        }
        // Scrub strip: a frozen band pinned to the top of the VISIBLE grid (the
        // note grid vertical-scrolls under it), so it's always reachable — a drag
        // seeks the transport (m10-e). Sits over the grid area only, past the
        // keyboard gutter.
        .overlay(alignment: .topLeading) { scrubStrip }
        // m25-b-2 — the viewport minimap, floating in the corner. Placed on the
        // EDITOR rather than on the grid content for the `offClipCueBand` reason:
        // it is viewport furniture, not a timeline object, so it must not scroll
        // away with the notes it maps. Topmost of the editor's overlays — it is the
        // only one here that takes a gesture from a corner nothing else claims.
        .overlay(alignment: .bottomTrailing) { minimapOverlay }
        // m25-a-2 — the auto-extend refusal, standing over the grid the note was
        // placed on. TOPMOST, because a message the user must read is worth more
        // than any furniture it briefly covers, and it costs that furniture
        // nothing: `ArrangeRefusalBubble` is `allowsHitTesting(false)`, so every
        // gesture underneath still lands. On the EDITOR rather than on the grid
        // CONTENT for the `offClipCueBand` reason — it is viewport furniture and
        // must not scroll away from the eye it is trying to reach.
        .overlay(alignment: .topLeading) { autoExtendNoticeBubble }
        }
    }

    /// The note grid's right-click menu (m23-cf) — one destructive entry.
    ///
    /// ⚠️ NOT DENSITY-GATED, unlike the arrange clip menu's edit entries (sp-c).
    /// Removing a note you added is not Pro edit chrome; it is the other half of
    /// adding one, and Simple is exactly the density a beginner who "cannot
    /// remove them" is working in.
    ///
    /// SELECTION-BASED, MIRRORING THE KEY PATH. `.contextMenu` gives its builder
    /// no click location and the notes are `Canvas`-drawn rather than per-note
    /// views, so a "delete the note under the pointer" menu would need a
    /// hover-tracked point plus a SECOND targeting policy beside the key
    /// handler's `guard !model.selection.isEmpty`. Reading the selection instead
    /// means the menu and the key can never disagree — and the title names the
    /// count, which the Edit-menu route cannot (`DeleteMenuPolicy`).
    ///
    /// SHOWN-BUT-DISABLED ON AN EMPTY SELECTION rather than an empty builder (the
    /// arrange menu's Simple-mode behaviour, which this deliberately does not
    /// copy): a menu that does not appear teaches nothing, and "the operation
    /// exists, it needs a selection" is precisely what the reported bug denied.
    @ViewBuilder
    private var noteContextMenu: some View {
        Button(DeleteMenuPolicy.noteContextTitle(selectedNoteCount: model.selection.count),
               role: .destructive) {
            // The key path's own two lines (`deleteSelection` + `commit`), never
            // a parallel mutation — so undo behaves identically through both
            // routes. `commit()` is the m23-al R6 funnel: a context-menu delete
            // IS the user acting inside the roll, so it claims ⌘+/⌘−/⌘0 exactly
            // as the double-tap add does.
            model.deleteSelection()
            commit()
        }
        .disabled(model.selection.isEmpty)
        // ═══ CUT / COPY / PASTE (m23-ek-3) ═══
        //
        // With NO ⌘C/⌘X/⌘V in v1 (the user's ruling — `ClipboardMenuPolicy`),
        // this menu is the fast path for notes, not a convenience. Each entry
        // routes into `applyClipboardRequest`, the SAME body the Edit menu
        // reaches through `clipboardNonce`, so the two routes cannot become two
        // policies.
        //
        // COUNTED TITLES, unlike the Edit menu's "Copy Selected Notes": this
        // builder runs inside the roll and can read `model.selection.count`
        // directly, where the Edit menu can only see the bridge's Bool.
        //
        // SHOWN-BUT-DISABLED on an empty selection — a menu that does not appear
        // teaches nothing.
        Button(ClipboardMenuPolicy.noteContextTitle(
            verb: .cut, selectedNoteCount: model.selection.count)) {
                applyClipboardRequest(.cut)
        }
        .disabled(model.selection.isEmpty)
        Button(ClipboardMenuPolicy.noteContextTitle(
            verb: .copy, selectedNoteCount: model.selection.count)) {
                applyClipboardRequest(.copy)
        }
        .disabled(model.selection.isEmpty)
        // ⚠️ PASTE IS TITLED AND ENABLED FROM THE LIVE CLIPBOARD, which reaches
        // this view as an ordinary observable property rather than as a staged
        // nonce payload — so it is correct the moment anything in the app copies
        // notes, with no request having to have run first.
        Button(ClipboardMenuPolicy.notePasteContextTitle(noteCount: clipboardNotes.count)) {
            applyClipboardRequest(.paste)
        }
        .disabled(clipboardNotes.isEmpty)
    }

    /// The cyan transport playhead inside the grid content (beta m10-e). Same
    /// visual idiom as the arrange playhead — a glowing cyan hairline offset by
    /// `localBeat · pixelsPerBeat` — drawn ONLY while the transport is inside the
    /// edited clip; off-clip the band shows `offClipCueBand` instead (m23-c1 —
    /// the absence is annotated, the line is still never parked at an edge).
    /// Cyan is the active-state accent, never violet, even for an AI clip whose
    /// notes are violet (Rule 3).
    @ViewBuilder
    private var gridPlayhead: some View {
        if let x = PianoRollPlayhead.lineX(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat) {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 1.5, height: model.contentHeight)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    /// The rubber band itself (m23-ek-1): a translucent cyan wash with a thin
    /// bright edge and an earned glow — the SAME visual vocabulary as the
    /// arrange's `marqueeBandView`, because it is the same gesture on a
    /// different surface and docs/DESIGN-LANGUAGE.md's whole point is that one
    /// meaning has one look. Cyan is active state, the glow recipe is core +
    /// bloom, and nothing static ever glows: this exists only while a gesture is
    /// live. Hit-test-inert, so it can never eat the drag that is drawing it.
    @ViewBuilder
    private var marqueeBandView: some View {
        if let band = marqueeBand, band.width > 0, band.height > 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(DAWTheme.playback.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(DAWTheme.playback.opacity(0.85), lineWidth: 1))
                .glow(DAWTheme.playback, radius: 6, intensity: 0.35)
                .frame(width: band.width, height: band.height)
                .offset(x: band.minX, y: band.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Group compress / extend handle (m25-g)

    /// Width of the DRAWN bar, as distinct from `PianoRollGroupScale.grabWidth`,
    /// which is the 12-pt zone that ROUTES the press. Deliberately different
    /// numbers: an affordance you can hit from further away than it looks is
    /// forgiving, one you can only hit exactly where it looks is a test of aim
    /// (the arrange's trim edges make the same split).
    private static let groupScaleHandleBarWidth: CGFloat = 4

    /// Which handle to draw, or nil for none.
    ///
    /// Two sources, and the second one matters: while a scale is IN FLIGHT the
    /// handle is drawn from `activeDrag`, not from hover — SwiftUI suspends
    /// hover updates under a captured pointer, so a hover-only rule would make
    /// the handle vanish the instant the user grabbed it.
    private var visibleGroupScaleEdge: PianoRollGroupScale.Edge? {
        if case .groupScale(let edge) = activeDrag { return edge }
        guard activeDrag == .none, let point = hoverPoint else { return nil }
        // m25-x — the LIVE chord, so the bar retracts the instant ⇧ or ⌘ goes
        // down. `pointerModifiers` is `@State`-backed, so this re-evaluates on
        // the modifier's edge with no pointer movement, which is the whole
        // reason the flags monitor exists.
        if case .groupScaleHandle(let edge) = hoverTarget(at: point,
                                                          modifiers: pointerModifiers) {
            return edge
        }
        return nil
    }

    /// The handle: a short vertical bar hugging the selection's edge, in the
    /// note's own accent (cyan, or violet for AI-generated material) with the
    /// core+bloom glow — docs/DESIGN-LANGUAGE.md's rule that nothing static ever
    /// glows is respected, since this exists only while the pointer is on it or
    /// the gesture is live.
    ///
    /// It sits INSIDE the grab band, hugging the selection: the leading bar at
    /// the band's right edge, the trailing bar at its left. So the bar is always
    /// the nearest thing to the notes it will scale, while the forgiving 12-pt
    /// zone extends away from them into empty grid.
    ///
    /// Hit-test-inert, like every other overlay on this surface: the press it
    /// advertises is routed by `beginGesture`, and an overlay that ate presses
    /// would break `.contextMenu` and the double-tap add for the same points
    /// (the m23-cf measurement).
    @ViewBuilder
    private var groupScaleHandleView: some View {
        if let edge = visibleGroupScaleEdge, let frame = model.groupScaleFrame() {
            let band = PianoRollGroupScale.handleRect(frame: frame, edge: edge)
            RoundedRectangle(cornerRadius: 2)
                .fill(noteColor.opacity(0.9))
                .frame(width: Self.groupScaleHandleBarWidth, height: band.height)
                .glow(noteColor, radius: 5, intensity: 0.5)
                .frame(width: band.width, height: band.height,
                       alignment: edge == .leading ? .trailing : .leading)
                .offset(x: band.minX, y: band.minY)
                // NO `.help` — a `.allowsHitTesting(false)` view has no hit
                // region for AppKit to hang a tooltip on, so one here would be
                // dead text. The affordance speaks through the cursor
                // (`PianoRollHover.cursor`) instead, which is the same way the
                // arrange's trim edges announce themselves.
                .allowsHitTesting(false)
        }
    }

    // MARK: - Playhead-place ghost line (m25-o)

    /// Where the ⌘-click would land, previewed as the house **hover ghost line**:
    /// docs/DESIGN-LANGUAGE.md's *"1 pt `textSecondary` line at 0.35 opacity
    /// marking the snapped beat under the pointer — deliberately NO glow"*.
    ///
    /// ⭐ **THIS IS WHERE "respect snap model" BECOMES VISIBLE.** The user asked
    /// for the snap and for an affordance; the cursor can say *a playhead is what
    /// this click places*, but only the line can say *and it lands HERE, on this
    /// grid line, not under your pointer*. With snap on it visibly jumps between
    /// lines as the pointer crosses the midpoint, which teaches the snap setting
    /// better than any label.
    ///
    /// ⚠️ **NO GLOW, AND NOT CYAN — the rule is quoted above and it is load
    /// bearing.** Glow is earned by transport state, and cyan IS the transport in
    /// this view. A glowing cyan line at the pointer would be pixel-indistinguishable
    /// from the real playhead, so the preview would be claiming the transport had
    /// already moved. Neutral + flat is the difference between a hint and a lie.
    ///
    /// Gated on `activeDrag == .none` (the `visibleGroupScaleEdge` precedent — a
    /// preview during a live gesture is stale by definition) and on the same
    /// resolver the click obeys, so the line appears exactly when the click would
    /// act. Hit-test-inert, like every other overlay here.
    ///
    /// ⚠️ **KNOWN LIMIT, STATED BECAUSE THE COMMENT ABOVE ARGUES PREVIEWS MUST
    /// NOT LIE: `hoverPoint` needs pointer MOVEMENT.** It is written only by
    /// `.onContinuousHover`, so if the content scrolls under a motionless
    /// ⌘-holding pointer — follow-playhead during playback, or an edge-drag
    /// auto-scroll — the stored content x names a beat the pointer is no longer
    /// over, and this line drifts away from the cursor until the mouse moves
    /// again. **The CLICK stays correct regardless**: `endGesture` reads the live
    /// press point and never consults `hoverPoint`, so the divergence is
    /// cosmetic and self-heals on the next pointer event. It is inherited from
    /// the m25-g hover facility rather than introduced here (`visibleGroupScaleEdge`
    /// has the identical exposure), and fixing it means giving the roll a
    /// scroll-aware hover reader — a change to the ONE reader every consumer
    /// shares, which is more than this item should spend.
    @ViewBuilder
    private var playheadPlaceGhost: some View {
        // ⚠️ `commandHeld` IS TESTED FIRST, AND IT IS NOT A SECOND DECISION.
        // `pointerModifiers` is derived from this same flag, so `!commandHeld`
        // ⟹ empty chord ⟹ `placesPlayhead` is false — a PROVEN-NECESSARY
        // precondition, not a competing rule, and the resolver below is still the
        // only thing that decides. What it buys is real: `model.hitTest` walks
        // `noteRects()`, which ALLOCATES AN ARRAY, and this body re-evaluates on
        // the transport tick. Without the short-circuit every playing frame pays
        // for a hit test whose answer cannot matter (docs/DESIGN-LANGUAGE.md's
        // no-allocation-per-frame rule).
        if commandHeld, activeDrag == .none, let point = hoverPoint,
           PianoRollGridPress.placesPlayhead(noteID: model.hitTest(point)?.id,
                                             modifiers: pointerModifiers) {
            Rectangle()
                .fill(DAWTheme.textSecondary.opacity(0.35))
                .frame(width: 1)
                .offset(x: CGFloat(placementLocalBeat(atContentX: point.x,
                                                      snapBypassed: snapBypassHeld))
                    * model.pixelsPerBeat)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Off-clip edge cue (m23-c1)

    /// The off-clip cue value — non-nil EXACTLY when the playhead line is absent
    /// (`PianoRollPlayhead.offClipCue` is gated on the same `isVisible` predicate
    /// `lineX` is). ONE value feeds both drawing bands, so the note grid and the
    /// velocity lane cannot disagree about where the transport is.
    private var offClipCue: PianoRollPlayhead.OffClipCue? {
        PianoRollPlayhead.offClipCue(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// Band-aligned wrapper the playhead bands overlay (the note grid, plus the
    /// velocity lane in Pro — the controller strip carries neither the line nor
    /// the cue): the shared 54 pt gutter spacer
    /// followed by the cue at EXACTLY `bandViewportWidth` — the one number the
    /// grid, velocity lane and controller strip already share. Deriving both
    /// bands' rect from it makes the leading AND the TRAILING edge agree
    /// structurally rather than coincidentally (each band's own scroller
    /// furniture differs, so measuring per-band would let the trailing cue drift
    /// between them by the scroller width).
    ///
    /// Anchored to the VIEWPORT, not to the clip's boundary: that is what makes
    /// it furniture rather than a timeline claim, and it keeps the cue on screen
    /// at any scroll offset. Accepted tradeoff — with the m18-f viewport
    /// extension the drawn band can run past the clip's end, so a trailing cue
    /// can sit to the right of the visible clip end; anchoring to the clip edge
    /// instead would need a horizontal scroll reader the velocity lane does not
    /// have and would reintroduce exactly the two-band divergence this prevents.
    @ViewBuilder
    private func offClipCueBand(topInset: CGFloat) -> some View {
        if let cue = offClipCue {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.keyboardWidth)   // gutter — no cue here
                OffClipEdgeCue(cue: cue, topInset: topInset)
                    .frame(width: bandViewportWidth)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    /// Reads the editor panel's full width for the m18-f band extension. A
    /// background (never hit-tested), updated only when the width actually
    /// changes — a window/splitter resize, never a playback tick.
    private var panelWidthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width, initial: true) { _, newValue in
                    panelWidth = newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// Reads the grid content's leading x in the scroll viewport space → the live
    /// horizontal scroll offset. A background (behind the grid, never hit-tested),
    /// updated only when the offset actually changes.
    private var gridScrollReader: some View {
        GeometryReader { geo in
            let leadingX = geo.frame(in: .named(Self.gridScrollSpace)).minX
            Color.clear
                .onChange(of: leadingX, initial: true) { _, newValue in
                    gridScrollX = -newValue
                    // Ground truth for follow (m23-c2): this is the ONLY place the
                    // roll learns where its scroller actually sits, so it is also
                    // where a MANUAL scroll is detected — an offset that diverges
                    // from the one follow asked for, while playing, with the
                    // geometry unchanged, is the user, and follow stands down.
                    // `followDrives`, not the raw flag: off-clip follow issues
                    // nothing, so it must not blame the user for scrolling either.
                    follow.reportOffset(-newValue,
                                        isEnabled: followDrives,
                                        isPlaying: isPlaying,
                                        contentWidth: gridDrawnWidth,
                                        viewportWidth: bandViewportWidth)
                }
        }
        .allowsHitTesting(false)
    }

    /// The frozen scrub band: a RULER over the top of the grid (past the keyboard
    /// gutter) whose drag SEEKS the transport. Click jumps, drag scrubs
    /// continuously — **ON THE SNAP GRID, with ⌥ for a free fine scrub (m25-o-2,
    /// user ruling 2026-08-13).** ⚠️ This line read *"free (unsnapped), the
    /// deliberate pro default"* for four milestones and that stance is now
    /// SUPERSEDED, not merely unimplemented: the user ruled that one snap model
    /// governs playhead positioning in the roll and the arrange alike. Works while
    /// playing and stopped (mid-play seek is supported engine behavior). The
    /// `resizeLeftRight` cursor advertises it (a horizontal position drag), held
    /// through the drag by `DragCursor` (docs/DESIGN-LANGUAGE.md pointer family).
    ///
    /// ⚠️ **m25-f-5 CHANGED THE LOOK, NOT THE BEHAVIOUR.** The band was
    /// `Color.clear` for four milestones and a user reported *"I can't position
    /// the playhead in the note editor"* — the feature worked, and nothing on
    /// screen said it existed. A hover cursor and a `.help` tooltip only reach a
    /// pointer that is already inside the strip, which is not the state the report
    /// came from. It now draws a ground, clip-local bar/beat numbers and a visible
    /// cyan playhead handle (`PianoRollScrubRulerBand`). The gesture below is
    /// untouched, `onSeek` is still the scrub's ONLY side effect, and nothing
    /// about it reached the wire (the m10-c/sp-b pure-view rule).
    ///
    /// The ruler is a BACKGROUND of the hit area rather than an overlay on it, so
    /// the `contentShape`/`hoverCursor`/`gesture` chain still owns every point of
    /// the band — a ruler drawn over the gesture would be a decoration that ate
    /// the drag it advertises.
    ///
    /// **Shown in both densities.** A ruler is navigation, not edit chrome (the
    /// arrange zoom cluster's rule), and Simple is precisely the density the user
    /// who could not find this was working in.
    private var scrubStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.keyboardWidth)   // gutter — no scrub here
            Color.clear
                .frame(maxWidth: .infinity)
                .background {
                    PianoRollScrubRulerBand(
                        lengthBeats: clip.lengthBeats,
                        beatsPerBar: beatsPerBar,
                        pixelsPerBeat: model.pixelsPerBeat,
                        contentWidth: gridDrawnWidth,
                        scrollX: gridScrollX,
                        positionBeats: positionBeats,
                        clipStartBeat: clip.startBeat)
                }
                .contentShape(Rectangle())
                .hoverCursor(.resizeLeftRight)
                .gesture(scrubDrag)
                .help("Scrub — drag to move the playhead")
        }
        .frame(height: Self.scrubStripHeight)
    }

    /// ⭐⭐ **m25-o-2 — THE SCRUB NOW SNAPS, BY USER RULING (2026-08-13).** It ran
    /// free for four milestones; the user ruled that one snap model governs
    /// playhead positioning on both surfaces, so this drag routes through the
    /// SAME `placementLocalBeat` the ⌘-click and the line drag use, with ⌥ as the
    /// arrange's fine escape. `PianoRollPlayhead.scrubProjectBeat` — the old
    /// unsnapped mapping — is deliberately no longer called from here; see its
    /// doc for why it survives and must not be wired back.
    private var scrubDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                onEngage()   // m23-al R2 — ruler scrub
                DragCursor.set(.resizeLeftRight)
                // Strip-local x=0 is the grid's left edge (unscrolled); add the
                // live scroll offset to recover the content beat. ⚠️ This is the
                // ONE place `gridScrollX` belongs — the strip does not scroll
                // with the content, while every grid point already is content
                // space (`placementLocalBeat`'s own warning).
                let contentX = value.location.x + gridScrollX
                onSeek(PianoRollPlayhead.projectBeat(
                    localBeat: placementLocalBeat(atContentX: contentX,
                                                  snapBypassed: snapBypassHeld),
                    clipStartBeat: clip.startBeat,
                    lengthBeats: clip.lengthBeats))
            }
            .onEnded { _ in DragCursor.clear() }
    }

    // MARK: - Grid gesture (move / resize / click-select)

    /// Rest cursor over the note grid: mirror the `gridDrag` hit routing so the
    /// hover cue matches what a press would do (a note body grabs, its Pro resize
    /// handle resizes, empty grid keeps the arrow — double-click-to-add doesn't
    /// warrant a crosshair on a single hover).
    private func gridCursor(at point: CGPoint) -> CursorKind? {
        let hit = model.hitTest(point)
        // m25-o — ⌘ over anything that is not a note turns the pointer into the
        // playhead-place bar. Asked of the SAME resolver `endGesture` obeys, with
        // the same two inputs, so the promise and the performance are literally
        // one function's answer (`PianoRollHover`'s one-resolver argument, applied
        // to the chord instead of the geometry).
        if PianoRollGridPress.placesPlayhead(noteID: hit?.id, modifiers: pointerModifiers) {
            return .verticalBar
        }
        return PianoRollHover.cursor(for: hoverTarget(at: point, hit: hit,
                                                     modifiers: pointerModifiers))
    }

    /// The chord the HOVER AFFORDANCES are allowed to reason about (m25-o, and
    /// widened to ⇧ by m25-x) — the cursor, the group-scale bar and the playhead
    /// ghost line all reason from this one value.
    ///
    /// ⭐ **⇧ IS TRACKED SINCE m25-x, AND THE NOTE THAT USED TO REFUSE IT IS
    /// RECORDED ON `shiftHeld` RATHER THAN DELETED.** Short version: ⇧ is a
    /// TOGGLING chord (`ArrangeClickIntent`), so `PianoRollHover.target` retracts
    /// the group-scale handle under it; without ⇧ in this set the bar would keep
    /// drawing while ⇧-click did nothing.
    ///
    /// ⚠️ **WIDENING THIS CHANGED NOTHING ELSE, AND THAT WAS CHECKED CHORD BY
    /// CHORD against `PianoRollGridPress.release`:** `[.shift]` on empty is
    /// `.doNothing` and on a note is `.toggle`, so `placesPlayhead` stays false
    /// and neither the ⌘ cursor nor the ghost line appears; `[.shift, .command]`
    /// resolves `.positionPlayhead` exactly as the bare `[.command]` this used to
    /// report for that same physical chord. The only pixel that moves is the
    /// group-scale bar.
    private var pointerModifiers: ArrangeClickModifiers {
        var chord: ArrangeClickModifiers = []
        if commandHeld { chord.insert(.command) }
        if shiftHeld { chord.insert(.shift) }
        return chord
    }

    // MARK: - ⌘ tracking (playhead-place affordance, m25-o)

    /// Mirrors `TimelineLanesView.ClipBlock`'s ⌥ tracking, including its first
    /// line: the CURRENT flags are read at start, because entering the grid with ⌘
    /// ALREADY down produces no `.flagsChanged` event at all — without this the
    /// affordance would appear only after the user released and re-pressed ⌘,
    /// which reads as "it works sometimes".
    private func startFlagsMonitor() {
        commandHeld = NSEvent.modifierFlags.contains(.command)
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            commandHeld = event.modifierFlags.contains(.command)
            // m25-x — read from the SAME event. `.flagsChanged` already fires on
            // every ⇧ transition, so this costs one `contains` and no wake-ups.
            shiftHeld = event.modifierFlags.contains(.shift)
            return event
        }
    }

    /// Removes the monitor and drops the affordance. Safe to call when none is
    /// installed, which is what lets the three teardown paths overlap freely.
    private func stopFlagsMonitor() {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        commandHeld = false
        shiftHeld = false
    }

    /// ⭐ **THE ONE PRODUCER OF "where a ⌘-click puts the playhead" (m25-o)** — the
    /// clip-local beat, snapped and clamped, for a grid CONTENT x.
    ///
    /// Both consumers go through here: the ghost line the user sees BEFORE
    /// clicking, and the seek the click performs. That is the whole reason it is a
    /// function — a preview computed by different arithmetic than the action is a
    /// preview that lies, and on a snapping surface it would lie by up to half a
    /// grid cell, which is exactly the error the user would notice.
    ///
    /// ⚠️ **`x` IS ALREADY GRID CONTENT SPACE — DO NOT ADD `gridScrollX`.**
    /// `gridDrag` and `.onContinuousHover` both report in the grid's content
    /// coordinates (the same points `model.hitTest` consumes, which is why note
    /// clicks land). The scroll offset is added only by `scrubDrag`, whose strip
    /// does not scroll with the content. Adding it here would put the playhead one
    /// viewport-width off at any scrolled position.
    ///
    /// ⚠️ **SNAPPED ONCE, HERE, IN CLIP-LOCAL SPACE.** Snapping is a property of
    /// the GESTURE (m23-g2), not of the click site, and `effectiveSnap` already
    /// carries Simple's forced `.beat`. `model.snap` passes the value straight
    /// through (floored at 0) when snapping is off — which IS the user's ruling
    /// verbatim: *"snap it to the position of the grid when snap is on, and
    /// anywhere in clip when it is [off]"* — so there is no second "is snapping
    /// on?" branch anywhere in this feature.
    ///
    /// ⭐⭐ **m25-o-2 MADE THIS THE ONE PRODUCER FOR ALL THREE PLAYHEAD GESTURES**
    /// — the ⌘-click, the new line drag, AND the 18 pt scrub strip. The strip
    /// scrubbed FREE (unsnapped) for four milestones as "the deliberate pro
    /// default"; the user overruled that on 2026-08-13 (*"it should follow the
    /// same rules"*), so the roll now has ONE snap behaviour instead of a click
    /// that snapped and a drag beside it that did not.
    ///
    /// ⚠️ **`snapBypassed` IS ⌥, AND IT IS INHERITED FROM THE ARRANGE, NOT
    /// INVENTED.** `TimelineLanesView.pointerBeat(forX:)` reads
    /// `NSEvent.modifierFlags.contains(.option)` for exactly this, on exactly
    /// these gestures (its ghost line, its empty-lane click-seek and its playhead
    /// scrub alike). Shipping the snap WITHOUT the hatch would make the roll's
    /// scrub strictly coarser than the arrange's — the one regression the item
    /// that deferred this work named in advance. It is read live per tick rather
    /// than tracked in a monitor, again as the arrange does: `commandHeld` exists
    /// only because a modifier must be visible BEFORE a press for the ⌘
    /// affordance, and ⌥ here changes a value mid-drag, where the live read is
    /// both correct and free.
    private func placementLocalBeat(atContentX x: CGFloat,
                                    snapBypassed: Bool = false) -> Double {
        let raw = model.beat(forX: x)
        let snapped = snapBypassed ? raw : model.snap(beat: raw, resolution: effectiveSnap)
        return min(max(0, snapped), max(0, clip.lengthBeats))
    }

    /// ⌥ held right now — the arrange's fine-scrub escape hatch, read the same
    /// way `TimelineLanesView.pointerBeat(forX:)` reads it.
    ///
    /// ⚠️ NOT routed through `ArrangeClickModifiers`: that OptionSet carries only
    /// `.shift` and `.command`, and widening it would touch every chord table in
    /// the app (`ArrangeClickIntent`, `PianoRollGridPress`, the arrange's own
    /// click routing) to serve one modifier that no selection rule reads.
    private var snapBypassHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// THE ONE hover resolution for this surface (m25-g) — what is under a point
    /// on the note grid. The rest cursor, the group handle overlay and
    /// `beginGesture`'s press routing all come through here, so the affordance
    /// the surface ADVERTISES and the gesture it PERFORMS cannot disagree.
    ///
    /// ⚠️ The Pro gate is NOT applied here: `PianoRollHover.target` owns it, for
    /// both note resize handles and the group handle, precisely so this file
    /// stops carrying two copies of it.
    private func hoverTarget(at point: CGPoint,
                             modifiers: ArrangeClickModifiers) -> PianoRollHoverTarget {
        hoverTarget(at: point, hit: model.hitTest(point), modifiers: modifiers)
    }

    /// The same resolution for a caller that has ALREADY hit-tested — every
    /// press has — so a press does not pay for a second `hitTest`.
    ///
    /// ⚠️ **`modifiers` IS CALLER-SUPPLIED AND THE TWO CALLERS PASS DIFFERENT
    /// THINGS ON PURPOSE (m25-x).** Hover passes `pointerModifiers` (the
    /// flags-monitor state — the only way to know a modifier is down with the
    /// mouse still); `beginGesture` passes the gesture's OWN chord. See
    /// `PianoRollHover`'s "the chord is an input" note for why unifying them
    /// would be a regression rather than a cleanup.
    private func hoverTarget(at point: CGPoint,
                             hit: (id: UUID, zone: NoteZone)?,
                             modifiers: ArrangeClickModifiers) -> PianoRollHoverTarget {
        PianoRollHover.target(
            at: point,
            hit: hit,
            selectionFrame: model.groupScaleFrame(),
            proDensity: mode == .pro,
            // m25-x — the chord, so the drawn handle and the cursor cannot
            // advertise a group scale the chord has already taken away.
            modifiers: modifiers,
            // m25-o-2 — the DRAWN line's x, nil when the transport is outside
            // the clip. The grab band is therefore gated on the same predicate
            // the pixels are (`PianoRollPlayhead.isVisible`, via `lineX`), so
            // the roll can never offer a grab on a line it is not drawing.
            playheadX: PianoRollPlayhead.lineX(
                position: positionBeats, clipStartBeat: clip.startBeat,
                lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat))
    }

    private var gridDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeDrag == .none {
                    beginGesture(at: value.startLocation, modifiers: .current)
                    didMove = false
                    // Hold the drag cursor for the whole gesture (grabbing while
                    // moving a note, resize while dragging its right edge).
                    switch activeDrag {
                    case .move: DragCursor.set(.grabbing)
                    // m25-g — the group handle is an edge drag, so it holds the
                    // same cursor a note resize does.
                    case .resize, .groupScale: DragCursor.set(.resizeLeftRight)
                    // m25-o-2 — the playhead scrub HOLDS the vertical bar for
                    // the whole drag, rather than closing a hand the way a
                    // movable body does.
                    //
                    // ⚠️ **THIS DIVERGES FROM THE ARRANGE, WHICH CLOSES THE HAND**
                    // (`CursorAffordance.playhead.dragCursor == .grabbing`), and
                    // the divergence is chosen, not overlooked. `CursorAffordance`'s
                    // own convention is that only movable BODIES close the hand
                    // while POSITION surfaces keep their cursor through the drag
                    // (the fader and trim-edge families), and the transport
                    // position is a position, not a body. The user also named
                    // this shape twice — "cursor turns into some vertical sign",
                    // then "the vertical visual element". Consolidating the
                    // arrange onto it is filed, not done: it would change a
                    // shipped surface this item has no mandate over.
                    case .playheadDrag: DragCursor.set(.verticalBar)
                    // `.marquee` sets NO drag cursor: the arrow is correct for a
                    // sweep (`DragCursor` is the grab/resize family), and this
                    // branch cannot be reached at press anyway — promotion
                    // happens later, inside `applyGesture`.
                    case .click, .marquee, .none, .cancelled: break
                    }
                }
                applyGesture(value)
            }
            .onEnded { value in
                endGesture(at: value.location, modifiers: .current)
                DragCursor.clear()
            }
    }

    /// The press, with the chord passed in — so the staging seam can drive the
    /// SAME handler the mouse drives (a synthesized gesture carries no real
    /// `NSEvent.modifierFlags`; `ArrangeClickModifiersBridge.current`'s own note).
    ///
    /// ⚠️ ONE FUNCTION, NOT A WRAPPER PAIR, and that is a pin rather than a
    /// preference: `onEngage()` (m23-al R1) lives INSIDE it, so the staged press
    /// engages the roll exactly as the mouse does. An outer wrapper that owned
    /// the engagement would put a TENTH `onEngage()` call in this file and let
    /// the seam drive a press that never claimed the surface — a seam that
    /// cannot fail the way the product can.
    ///
    /// ⚠️ m23-ek-1 ROUTES THE CHORD THROUGH `ArrangeClickIntent`, WHICH CHANGES
    /// SHIPPED ⌘ BEHAVIOUR IN THE ROLL. Until now this read
    /// `NSEvent.modifierFlags.contains(.shift)` raw, so ⌘ did nothing here at
    /// all: ⌘-press on a note started a MOVE, and ⌘-click on empty grid CLEARED
    /// the selection. `ArrangeSelection.swift:89-91` is the app's ONE chord→intent
    /// mapping and says shift and ⌘ both mean TOGGLE, deliberately.
    ///
    /// Three behaviours change, all toward arrange consistency, and each has its
    /// own test/probe leg because a change to shipped pointer behaviour with no
    /// assertion naming it is how a regression ships as a feature:
    ///   ⌘-press on a note + drag  →  toggles it on release, no move
    ///   ⌘-click on a note         →  toggles it (was: selects only it)
    ///   ⌘-click on empty grid     →  leaves the selection alone (was: cleared)
    /// Shift behaviour is unchanged in every case.
    ///
    /// The alternative — routing only the BAND through the mapping — was
    /// rejected: the band's whole correctness argument is "the chord means the
    /// same thing on a band as on a click", which is false unless the click side
    /// moves too, and it would grow the second chord table
    /// `ArrangeClickIntent`'s doc exists to prevent.
    private func beginGesture(at start: CGPoint, modifiers: ArrangeClickModifiers) {
        // m23-al R1 — THE grid press funnel: note click, move, resize and
        // empty-grid click all arrive here through `gridDrag`. Kept even though R6
        // (`commit`) covers every MUTATING gesture, because this fires on a
        // SELECTION-ONLY click (`activeDrag = .click` below), which mutates
        // nothing and must still claim the surface.
        onEngage()
        let toggling = ArrangeClickIntent.intent(for: modifiers) == .toggle
        let hit = model.hitTest(start)
        // m25-g — ONE resolution for cursor and press. `.groupScaleHandle` can
        // only come back when the point is over NO note (`PianoRollHover`
        // ranks notes above it), outside the selection's box
        // (`PianoRollGroupScale` decision 4), and — since m25-x — under a
        // NON-toggling chord, so no press that routed to a move or a resize
        // before this item routes anywhere else now.
        // m25-x — the GESTURE'S own chord, not the hover monitor's. Same
        // function, caller-supplied truth (`PianoRollHover`'s "the chord is an
        // input" note): this is the chord the press will actually be routed
        // with, and it is right even when the pointer entered the surface with a
        // modifier already down.
        let target = hoverTarget(at: start, hit: hit, modifiers: modifiers)
        // m25-o-2 — GRAB THE PLAYHEAD LINE. Gated on `!toggling` HERE rather
        // than in the resolver, and m25-x made that a deliberate split rather
        // than a coincidence: `.playhead` SURVIVES ⌘ in `PianoRollHover.target`,
        // because under ⌘ this press falls through to `.click(nil)` and releases
        // into `.positionPlayhead` — the transport still moves, just TO the
        // pointer rather than WITH it. Both show the same `.verticalBar` cursor,
        // so the affordance never disagrees with the gesture across the two, and
        // this gate is the only thing choosing between them.
        //
        // `.playhead` can only come back over bare grid — notes and the group
        // handle both outrank it (`PianoRollHover`'s ranking, which IS the
        // user's "no other elements under the mouse") — so no press that started
        // a move, a resize or a scale before this item routes anywhere else now.
        if !toggling, target == .playhead {
            activeDrag = .playheadDrag(scrubbing: false)
        } else if case .groupScaleHandle(let edge) = target {
            // ⭐ **NO `!toggling` HERE, AND THE ASYMMETRY WITH THE ARM ABOVE IS
            // THE WHOLE OF m25-x.** The RESOLVER now owns this rule: `target`
            // cannot return `.groupScaleHandle` under a toggling chord at all,
            // so a second gate here would be a second source of truth for one
            // rule — the exact shape that let the bar advertise a scale this
            // branch would refuse.
            //
            // The `.playhead` arm above KEEPS its gate because the resolver does
            // NOT own that one: `.playhead` survives ⌘ deliberately (⌘-click
            // still moves the transport, just TO the pointer rather than WITH
            // it), so `!toggling` there is load-bearing, not belt-and-braces.
            // Same for the two `.note` arms below — a ⌘-press on a note must
            // toggle rather than move it, and `.note` survives every chord.
            //
            // NO selection change: the group being scaled is the group the user
            // already selected, and a handle press that quietly re-selected
            // something would be the one way this gesture could lose notes.
            model.beginGroupScale(edge: edge)
            activeDrag = .groupScale(edge)
        } else if let hit, !toggling, case .note(_, .resizeHandle) = target {
            if !model.isSelected(hit.id) { model.selectOnly(hit.id) }
            activeDrag = .resize(hit.id)
        } else if let hit, !toggling {
            if !model.isSelected(hit.id) { model.selectOnly(hit.id) }
            // m23-ek-2: the grabbed note is the drag's ANCHOR — the one note
            // whose start snaps. Everything else in the selection translates
            // rigidly by the delta that produced it.
            model.beginMove(anchorID: hit.id)
            activeDrag = .move
        } else {
            activeDrag = .click(hit?.id)
        }
    }

    private func applyGesture(_ value: DragGesture.Value) {
        // m25-r — REMEMBER THE LIVE POINTER, so the repeat clock has something
        // to hold still. Captured HERE and not in `advanceGesture` on purpose:
        // this function is the live-mouse-only wrapper, and the staging seam
        // (which reaches `advanceGesture` directly) has no pointer that can be
        // held, so it must not be able to arm a clock.
        //
        // ⚠️ `value.location` and `gridScrollX` are read as a PAIR, off the same
        // laid-out geometry, because their DIFFERENCE is what gets stored. Both
        // describe the layout the event was hit-tested against, so a scroll
        // request still in flight biases neither.
        heldEdgePointer = PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: value.location.x, pointerContentY: value.location.y,
            origin: value.startLocation, currentOffset: gridScrollX)
        lastPointerEventAt = ContinuousClock.now
        // The live pointer's OWN quantities, passed through unchanged: no
        // geometry a real drag depends on is recomputed. The one thing that did
        // change is WHERE `.current` is read — it used to be evaluated inside the
        // `.click, .marquee` branch and is now evaluated on every tick, including
        // `.move` and `.resize`, where it goes unused. A modifier-flags read is
        // side-effect-free, so this is a cost, not a behaviour change.
        advanceGesture(translation: value.translation, location: value.location,
                       origin: value.startLocation, modifiers: .current)
        // ⚠️ ARMED ON `didMove`, NOT ON THE PRESS, and this is the one hazard the
        // clock introduces that the shipped per-event scroll does not have.
        // `DragGesture(minimumDistance: 0)` fires `onChanged` on the PRESS, so a
        // press on a note that happens to sit inside the 48 pt band already
        // collects one scroll step today — harmless, and invisible. Repeat that
        // at 60 Hz and a stationary CLICK becomes a runaway scroll-and-move. The
        // travel gate is the same `moveCommitSlop` that decides whether this
        // gesture is an edit at all, so nothing scrolls that would not also
        // commit.
        setEdgeRepeat(running: didMove && activeDragScrollsContent)
    }

    /// Whether the gesture in flight is one that drags CONTENT, and therefore
    /// one the edge scroll (and its repeat) applies to. The same three cases
    /// `advanceGesture` calls `autoScroll(towards:)` from, asked once.
    private var activeDragScrollsContent: Bool {
        switch activeDrag {
        case .move, .resize, .groupScale: return true
        // A band must not scroll the grid under itself (it would re-decide the
        // selection from a moving origin), a playhead scrub is aimed at a line
        // the user can SEE, and `.none`/`.cancelled` are not gestures.
        case .click, .marquee, .playheadDrag, .none, .cancelled: return false
        }
    }

    /// Starts or stops the held-at-edge repeat clock (m25-r). Idempotent, so the
    /// per-tick call in `applyGesture` cannot stack a second clock behind an
    /// overwritten handle — the `startFlagsMonitor` rule.
    private func setEdgeRepeat(running: Bool) {
        guard running != (edgeRepeatTask != nil) else { return }
        guard running else {
            edgeRepeatTask?.cancel()
            edgeRepeatTask = nil
            return
        }
        edgeRepeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: PianoRollEdgeRepeat.interval)
                guard !Task.isCancelled else { return }
                repeatHeldEdgeScroll()
            }
        }
    }

    /// ONE REPEAT TICK (m25-r) — what a held pointer does between real events.
    ///
    /// ⭐⭐ **IT SYNTHESISES NOTHING IT DOES NOT OBSERVE.** The pointer has not
    /// moved, so its position in the CONTENT changed by exactly the amount the
    /// content scrolled, and `gridScrollX` is where that scroll is observed. The
    /// tick therefore RECOMPUTES `localX + gridScrollX` from scratch rather than
    /// nudging a stored value: nothing integrates, so nothing drifts, and a
    /// frame's lag in the observation is erased by the next tick instead of
    /// accumulating. It is also the value SwiftUI itself would report, so the
    /// next real event agrees with these rather than contradicting them — which
    /// is the whole of the desync worry `PianoRollAutoScroll`'s no-timer note
    /// raised. `PianoRollEdgeRepeat`'s doc carries the argument in full.
    ///
    /// ⚠️ **THIS IS REASONING OVER CODE, NOT A MEASUREMENT.** No instrument here
    /// can watch a note track a cursor or feel a ramp; `PianoRollEdgeRepeatTests`
    /// pins the arithmetic (the dragged note's SCREEN position is invariant
    /// across a full run to the wall), and the feel needs a human hand.
    ///
    /// Deliberately routed through `advanceGesture` rather than doing its own
    /// work: the snap, the audition, the `didMove` bookkeeping and the scroll all
    /// stay spelled once, and a repeat is by construction unable to do something
    /// a real event would not.
    private func repeatHeldEdgeScroll() {
        guard didMove, activeDragScrollsContent, let held = heldEdgePointer,
              let since = lastPointerEventAt else { return }
        // Suppressed until the pointer has genuinely been still, so a MOVING
        // pointer behaves exactly as it did before this feature and the two step
        // sources can never add up. See `holdDelay` for why a duration and not a
        // "no event since the last tick" counter.
        guard PianoRollEdgeRepeat.isHeld(
            sinceLastPointerEvent: ContinuousClock.now - since) else { return }
        guard let tick = PianoRollEdgeRepeat.tick(
            held: held,
            observedOffset: gridScrollX,
            viewportWidth: bandViewportWidth,
            contentWidth: gridDrawnWidth) else { return }
        advanceGesture(translation: tick.translation, location: tick.location,
                       origin: held.origin, modifiers: .current)
    }

    /// ONE HOME for "the pointer moved" — every grid gesture's changed phase, for
    /// the live `gridDrag` and for `debug.pianoRollMarquee {act:"changed"}` alike.
    ///
    /// ⚠️ THE SEAM MUST REACH `.move` AND `.resize`, not just the band, and that
    /// is an anti-vacuity requirement rather than a convenience. A seam that could
    /// only ever drive a band would make the C5 leg ("a ⌘-drag TOGGLES a note and
    /// does not move it") pass against an implementation that cannot move a note
    /// at all — the negative would hold for the wrong reason. It is also the only
    /// way to observe m23-ek-1 and m23-ek-2 COMPOSING: band-select many notes,
    /// then drag them as one gesture, which is the entire point of the pair.
    ///
    /// `translation` is taken as a parameter rather than derived from
    /// `location - origin` so the live path keeps passing SwiftUI's own value
    /// verbatim; the seam, which has no `DragGesture.Value`, derives it.
    private func advanceGesture(
        translation: CGSize, location: CGPoint, origin: CGPoint,
        modifiers: ArrangeClickModifiers
    ) {
        switch activeDrag {
        case .playheadDrag(let scrubbing):
            // ⭐ m25-o-2 — THE SLOP GATE, AND IT IS THE ARRANGE'S RULE INHERITED
            // RATHER THAN A TUNING CHOICE: "grabbing the playhead without moving
            // must not jump it to a snapped beat" (`ArrangePointer.scrubSlop`).
            // On a snapping surface a press with no travel would displace the
            // transport by up to half a grid cell — the user reaches for the
            // line, touches it, and it leaves. Sticky once crossed, so a drag
            // that wanders back inside the slop keeps scrubbing.
            guard scrubbing || abs(translation.width) > PianoRollPlayhead.scrubSlop else { return }
            if !scrubbing { activeDrag = .playheadDrag(scrubbing: true) }
            // The SAME producer the ⌘-click and the ruler scrub use, so all
            // three playhead gestures land on the same beat for the same x.
            onSeek(PianoRollPlayhead.projectBeat(
                localBeat: placementLocalBeat(atContentX: location.x,
                                              snapBypassed: snapBypassHeld),
                clipStartBeat: clip.startBeat,
                lengthBeats: clip.lengthBeats))
            // ⚠️ NO `autoScroll(towards:)`, unlike every other branch here, and
            // that is deliberate. The playhead is being dragged to a beat the
            // user can SEE; auto-scrolling would move the content under a
            // gesture whose whole purpose is to aim at a visible line, and the
            // seek is clamped to the clip anyway, so the edge case it would
            // serve — scrubbing past the viewport — has nowhere to go.
            //
            // ⚠️ NO `didMove` either: `didMove` gates `commit(`, and moving the
            // playhead is not an edit. It owes the undo journal nothing.
        case .move:
            let deltaBeats = model.beat(forX: translation.width)
            let deltaPitch = -Int((translation.height / model.rowHeight).rounded())
            model.moveSelection(deltaBeats: deltaBeats, deltaPitch: deltaPitch, resolution: effectiveSnap)
            if abs(translation.width) > PianoRollMarquee.moveCommitSlop
                || abs(translation.height) > PianoRollMarquee.moveCommitSlop { didMove = true }
            // m23-d: hear the pitch you are dragging. Fired on EVERY tick,
            // including the very first one (deltaPitch == 0), so pressing a note
            // sounds it at its current pitch before any movement — Logic's
            // behavior, and intended. A no-change tick is free: the controller
            // below diffs, so no events are pushed when the set is unchanged.
            onAudition(selectedPitches, anchorVelocity)
            autoScroll(towards: location.x)
        case .resize(let id):
            model.resizeNote(id: id, toEndBeat: model.beat(forX: location.x), resolution: effectiveSnap)
            if abs(translation.width) > PianoRollMarquee.moveCommitSlop { didMove = true }
            autoScroll(towards: location.x)
        case .groupScale:
            // m25-g — the pointer's x IS the dragged edge's asked-for beat. It
            // goes in RAW: `scaleSelection` performs this gesture's one snap
            // (m23-ek-2 — snapping is a property of the gesture), and every
            // clamp is computed once over the whole group inside it.
            //
            // ⚠️ NO `onAudition` here, and that is a decision rather than an
            // omission. A move sounds the pitch you are dragging because the
            // gesture CHANGES pitch; a scale never touches pitch, so the only
            // honest audition would be to replay the whole scaled figure, which
            // is a transport job, not a drag job.
            model.scaleSelection(toBeat: model.beat(forX: location.x), resolution: effectiveSnap)
            if abs(translation.width) > PianoRollMarquee.moveCommitSlop { didMove = true }
            autoScroll(towards: location.x)
        case .click, .marquee:
            // m23-ek-1: the ONE home for promote-then-apply. The live gesture and
            // the staging seam both arrive here, so the threshold and the band
            // cannot be spelled twice.
            advanceMarquee(origin: origin, to: location, modifiers: modifiers)
        case .none, .cancelled:
            break
        }
    }

    /// EDGE-DRAG AUTO-SCROLL (m25-f-3) — drag a note towards the edge of the
    /// grid and the grid comes with you. The user's words: *"as user moves close
    /// to the edge of the note, it should expand/scroll the note area as well as
    /// auto extend clip if it reaches the edge."* This is the scroll half; the
    /// extend half is `endGesture`'s `commit(extendToCover:)`.
    ///
    /// ⭐⭐ **THE FOLLOW-PLAYHEAD PRECEDENCE DECISION IS THIS ONE LINE, and it is
    /// `jumpToMinimapTarget`'s decision re-used rather than a second policy: the
    /// scroll is delivered through `scrollExternally`, the MANUAL-SCROLL seam,
    /// so an edge drag IS a manual scroll and follow stands down on this surface
    /// for the rest of the take.** Dragging a note is unambiguously the user
    /// steering the viewport, so the alternative — follow yanking the grid back
    /// under a live gesture on the next transport tick — is not a tie that needs
    /// breaking. The chip drops to its PAUSED face, so the stand-down is VISIBLE
    /// rather than a silent tug-of-war.
    ///
    /// ⚠️ **`layout.followPlayhead` IS NOT WRITTEN**, for the reason recorded on
    /// `jumpToMinimapTarget`: that flag is the single PERSISTED enable the
    /// arrange lanes read too, so winning a piano-roll gesture with it would
    /// stand follow down on a surface the user never touched, and would outlive
    /// the gesture by every future session. Suspension is per-surface runtime
    /// state that re-arms on the next play. While STOPPED nothing is suspended
    /// at all — `reportOffset` is armed only during playback — so a drag with
    /// the transport parked simply re-baselines, which is the common case.
    ///
    /// ⚠️ All THREE horizontally scrolling bands move together and cannot
    /// desync: `scrollExternally` bumps ONE nonce that sets ONE `followTargetX`,
    /// and the grid, the velocity lane and the controller strip each scroll to
    /// their own marker sized off that same x. A velocity lane sliding out from
    /// under the note being dragged is therefore not reachable from here. None
    /// of the three animates ("a page turn must not glide"), so a per-tick
    /// re-issue cannot accumulate half-finished animations.
    ///
    /// The policy returns nil for "no scroll", which is what keeps the nonce
    /// quiet for the overwhelming majority of drag ticks — see
    /// `PianoRollAutoScroll` for why that matters and for the deliberate
    /// no-timer scope line.
    private func autoScroll(towards contentX: CGFloat) {
        guard let next = PianoRollAutoScroll.nextOffset(
            pointerContentX: contentX,
            currentOffset: gridScrollX,
            viewportWidth: bandViewportWidth,
            contentWidth: gridDrawnWidth) else { return }
        follow.scrollExternally(to: next)
    }

    /// Promote a TRAVELLED empty-grid press into a rubber band, then apply the
    /// band — the whole marquee state machine, in one place (m23-ek-1).
    ///
    /// Inert, by construction, for everything that must not become a band: a
    /// press ON a note (`.click(id)`), a press that has not travelled
    /// `PianoRollMarquee.dragSlop`, and any other gesture state.
    ///
    /// The travel is measured from the press point to the current point rather
    /// than from `DragGesture.Value.translation`, and the two are the same
    /// quantity for a live drag. That is what lets the staging seam exercise the
    /// REAL threshold: it has coordinates but no `DragGesture.Value`.
    @discardableResult
    private func advanceMarquee(origin: CGPoint, to point: CGPoint,
                                modifiers: ArrangeClickModifiers) -> Set<UUID> {
        switch activeDrag {
        case .click(let id):
            guard id == nil else { return [] }
            guard hypot(point.x - origin.x, point.y - origin.y)
                    >= PianoRollMarquee.dragSlop else { return [] }
            let base = model.selection
            let additive = ArrangeClickIntent.intent(for: modifiers) == .toggle
            activeDrag = .marquee(origin: origin, base: base, additive: additive)
            return updateMarquee(origin: origin, to: point, base: base, additive: additive)
        case .marquee(let origin, let base, let additive):
            return updateMarquee(origin: origin, to: point, base: base, additive: additive)
        // m25-g: a group scale can no more promote into a band than a move or a
        // resize can — promotion is gated on `.click(nil)`, and a handle press
        // never enters that state.
        //
        // ⚠️⚠️ **m25-o-2 — AND THIS IS THE ITEM'S REAL COST, NAMED RATHER THAN
        // DISCOVERED NEXT CYCLE: A MARQUEE CAN NO LONGER BE STARTED FROM THE
        // PLAYHEAD'S 8 pt STRIPE.** A band promotes out of `.click(nil)`, and a
        // press on the line is now `.playheadDrag` instead, so the stripe is
        // dead to rubber-banding — the same "dead stripe" shape m25-g accepted
        // for its handle band, here 8 pt wide and MOVING with the transport.
        //
        // ⚠️⚠️ **AND ITS DEFAULT HOME IS THE GRID'S LEFT EDGE, WHICH IS WHERE A
        // USER IS MOST LIKELY TO MEET IT.** With the transport stopped at 0 on a
        // clip starting at 0, `lineX` is 0 — so out of the box the stripe sits
        // at content x 0…4, and a band started by pressing exactly on the grid's
        // left edge will not promote. This is stated because "8 pt around the
        // playhead" reads as an exotic case and the x≈0 instance is the common
        // one; a reader who knows only the general statement will not think to
        // look here when a band near the origin does not start.
        //
        // Accepted, with the tradeoff stated: the band is startable one pixel
        // either side, the stripe is exactly where the user is aiming at the
        // playhead rather than at empty grid, and the arrange makes the
        // identical trade (its grab strip is a separate view that eats presses
        // outright). The alternative — demote a `.playheadDrag` into a band on
        // vertical travel — would invent a promotion rule neither surface has,
        // to serve a gesture the user can start a pixel away.
        case .move, .resize, .groupScale, .playheadDrag, .none, .cancelled:
            return []
        }
    }

    /// Re-decides the selection for the band's current free corner. Runs on
    /// EVERY update from the FROZEN base — so growing the band adds notes and
    /// shrinking it gives them back.
    @discardableResult
    private func updateMarquee(origin: CGPoint, to point: CGPoint,
                               base: Set<UUID>, additive: Bool) -> Set<UUID> {
        let band = PianoRollMarquee.band(from: origin, to: point)
        // Rects from the model — the SAME producer `hitTest` consumes, never
        // this view's own beat math (m23-ek-1's whole point).
        let hits = PianoRollMarquee.hits(band: band, rects: model.noteRects())
        marqueeBand = band
        model.applyMarquee(hits: hits, base: base, additive: additive)
        reportMarquee(hits: hits)
        return hits
    }

    /// Commits the final band and puts the band layer away.
    private func endMarquee(origin: CGPoint, at point: CGPoint,
                            base: Set<UUID>, additive: Bool) {
        let band = PianoRollMarquee.band(from: origin, to: point)
        let hits = PianoRollMarquee.hits(band: band, rects: model.noteRects())
        model.applyMarquee(hits: hits, base: base, additive: additive)
        marqueeBand = nil
        // ONE final report: band gone, selection final. A gate reading this
        // cannot mistake "the band was never drawn" for "the band is put away",
        // because the mid-drag reports carried a non-nil rect.
        reportMarquee(hits: hits)
    }

    /// Everything the seam echoes about this surface, taken from the model at
    /// the instant of the report.
    private var surfaceState: PianoRollSurfaceState {
        PianoRollSurfaceState(
            rowHeight: model.rowHeight, pixelsPerBeat: model.pixelsPerBeat,
            clipLengthBeats: model.clipLengthBeats, noteCount: model.draft.count,
            selection: model.selection)
    }

    /// Reports the band layer's live state UP (m23-ek-1). `marqueeBand` is
    /// passed as the STORED `@State` — the very value the overlay renders from,
    /// read back after it was written — so the echo is what was DRAWN and never
    /// what was intended.
    private func reportMarquee(hits: Set<UUID>) {
        noteSelection.reportMarquee(
            band: marqueeBand, hits: hits, surface: surfaceState,
            // GROUND TRUTH for "is a gesture still open", read off the state
            // machine itself. `.cancelled` counts as in flight on purpose: an
            // m18-i external reseed swallows the gesture but still owes a
            // release, exactly as the mouse does.
            gestureInFlight: activeDrag != .none)
    }

    /// Runs one debug-staged grid-gesture step through the LIVE handlers
    /// (m23-ek-1).
    ///
    /// ⚠️ NOT the arrange's `applyMarqueeStage` shape, and the difference is
    /// load-bearing rather than stylistic. `TimelineLanesView.applyMarqueeStage`
    /// arms a band at `begin` and applies a degenerate one immediately, because
    /// over there the band is its own gesture with its own `minimumDistance`.
    /// Here the band is a PROMOTION of a press, so a staged `begin` must do
    /// exactly what a real press does — enter `.click(nil)` and draw nothing —
    /// and promotion must remain reachable only through a `changed` past the
    /// slop. Copying the arrange's shape would arm a band the mouse could not,
    /// and the seam would then be unable to fail the way the product can.
    ///
    /// The chord is passed explicitly (`ArrangeClickModifiers`) and routed
    /// through the same `ArrangeClickIntent` mapping the mouse uses; the one
    /// line the seam therefore cannot exercise is the live `.current` read,
    /// exactly as `ArrangeClickModifiersBridge` records for the arrange.
    ///
    /// ⚠️ STRUCTURAL LIMIT, stated so a green gate is not read as more than it
    /// is: the seam feeds GRID CONTENT coordinates straight in, so it cannot
    /// catch a coordinate-space mismatch between the live `gridDrag` and the
    /// drawn band. The evidence that `DragGesture.Value`'s points are in this
    /// space is that `model.hitTest` already consumes them and note clicks work.
    private func applyMarqueeStage(_ stage: PianoRollMarqueeStage) {
        let point = CGPoint(x: stage.x, y: stage.y)
        var modifiers: ArrangeClickModifiers = []
        if stage.shift { modifiers.insert(.shift) }
        if stage.command { modifiers.insert(.command) }
        let seqBefore = noteSelection.marqueeReportSeq
        switch stage.action {
        case .begin:
            // The roll's OWN press funnel, including its `onEngage()` (m23-al R1)
            // and its hit routing: a staged press on a note starts a move exactly
            // as the mouse would, and only a press on EMPTY grid leaves the
            // `.click(nil)` state a band can be promoted out of.
            guard activeDrag == .none else { break }
            marqueeStageOrigin = point
            beginGesture(at: point, modifiers: modifiers)
        case .changed:
            guard let origin = marqueeStageOrigin else { break }
            // The SAME changed-phase funnel the pointer runs, so a staged step can
            // drive a move or a resize and not only a band (see `advanceGesture`).
            advanceGesture(
                translation: CGSize(width: point.x - origin.x, height: point.y - origin.y),
                location: point, origin: origin, modifiers: modifiers)
        case .end:
            marqueeStageOrigin = nil
            endGesture(at: point, modifiers: modifiers)
        }
        // EXACTLY ONE report per step, promoted or not — so the bounded wait
        // always has something to stand on and the echo is never the previous
        // step's. A step that armed no band (a press, a sub-slop drag, a
        // degenerate release) reports nothing on its own, so it is reported
        // here, with `bandRect: null` and no hits: the honest answer, and the one
        // the degenerate leg asserts.
        if noteSelection.marqueeReportSeq == seqBefore { reportMarquee(hits: []) }
    }

    /// The release. Takes the final point and the chord — never a
    /// `DragGesture.Value` — so the staging seam runs this exact handler.
    private func endGesture(at point: CGPoint, modifiers: ArrangeClickModifiers) {
        // ⚠️ THE STATE MACHINE IS CLOSED *BEFORE* THE BRANCH RUNS, not after.
        // `endMarquee` reports up from inside the `.marquee` branch, and that
        // report carries `gestureInFlight` read straight off `activeDrag` — so a
        // trailing reset would make the release echo "still dragging" for one
        // step. No branch below reads `activeDrag` (verified by enumerating every
        // reference in this file), so this is a pure reordering.
        let outgoing = activeDrag
        activeDrag = .none
        // m25-r — teardown 1 of 3. Stopped BEFORE the branch runs, alongside the
        // state-machine reset above and for the same reason: nothing below may
        // observe a gesture that has ended, and a clock is the loudest possible
        // way to observe one.
        setEdgeRepeat(running: false)
        heldEdgePointer = nil
        lastPointerEventAt = nil
        switch outgoing {
        case .playheadDrag(let scrubbing):
            // ⭐⭐ m25-o-2 — A NO-TRAVEL GRAB IS A CLICK ON EMPTY GRID, AND MUST
            // DESELECT LIKE ONE. This is m25-g's group-handle argument verbatim,
            // and it is the same bug both times: the grab band lies over empty
            // grid by construction (notes outrank the playhead), so before this
            // item EVERY press here was `.click(nil)` and released into
            // `clearSelection()`. Claiming the press for a scrub and then doing
            // nothing on a no-travel release would silently delete
            // click-to-deselect from an 8 pt stripe — which is m25-m's bug, a
            // fix a human confirmed by hand, reintroduced in a moving stripe.
            //
            // ⚠️ The RELEASE CHORD IS NOT CONSULTED, following `.groupScale`
            // exactly: `beginGesture` gates this state on `!toggling`, so the
            // press began with no ⌘/⇧, and re-reading the chord at release would
            // give this arm a second, differently-timed rule for no benefit.
            //
            // ⚠️ NO `onSeek` HERE — the seek already happened, per tick, in
            // `advanceGesture`. A trailing seek would also re-snap the landing
            // beat with a chord that may have changed mid-flight, and
            // `PianoRollPlayheadPlaceSiteTests` pins this body at exactly ONE
            // seek so the roll keeps one way to move the playhead.
            if !scrubbing { model.clearSelection() }
        case .move, .resize, .groupScale:
            // m25-f-3 — AUTO-EXTEND. `else` it was a plain click; selection
            // already set. See `autoExtendIDs(for:)` for what may grow the clip.
            //
            // ⚠️ m25-g's group scale joins this EXISTING branch rather than
            // adding its own `commit(` — `EditorSurfaceOwnershipSiteTests` pins
            // this file's `commit(` count as its R6 false-engage guard, and a
            // gesture that is already a `gridDrag` state has nothing new to say
            // about engagement.
            if didMove {
                commit(extendToCover: autoExtendIDs(for: outgoing))
            } else if case .groupScale = outgoing {
                // ⭐⭐ m25-g — A HANDLE PRESS THAT NEVER TRAVELLED IS A CLICK ON
                // EMPTY GRID, AND MUST BEHAVE LIKE ONE. The handle band lies
                // over empty grid by construction, so before this feature every
                // press there was `.click(nil)` and released into
                // `clearSelection()`. Claiming the press for a scale and then
                // doing nothing on a no-travel release would silently delete
                // click-to-deselect from a 12-pt strip running the full height
                // of the selection's bounding box — which is m25-m's bug
                // ("clicking empty space does not deselect"), reintroduced in a
                // stripe, days after a human confirmed it fixed.
                //
                // Two halves, both needed: put the draft back (a sub-slop drag
                // has already scaled it per tick, and nothing is about to commit
                // that), then clear, exactly as the `.click(nil)` branch does.
                // A ⇧/⌘ press never reaches here — `beginGesture` gates the
                // handle on `!toggling` — so the toggle chord keeps its
                // selection, byte-identically to before.
                model.cancelGroupScale()
                model.clearSelection()
            }
        case .click(let id):
            // ⭐ m25-o — THE FOUR-ARM TABLE, AND IT IS AN EXHAUSTIVE `switch` OVER
            // A HEADLESS RESOLVER RATHER THAN THE `if`/`else if` CHAIN IT REPLACES.
            //
            // The user anticipated the conflict this item creates — ⌘-click here
            // already means "add/remove from selection" — and asked for the guard
            // themselves. Their guard needs one more term (the HIT TEST), and the
            // resulting table has three arms that were already shipped and must
            // not move, so the shape of this code is doing real work: a chain of
            // `if`s can fire two arms or, worse, none, and it was a MISSING arm
            // that deleted click-to-deselect in m25-m. A `switch` over
            // `PianoRollGridRelease` cannot compile with a case unhandled and
            // cannot run two.
            //
            // ⚠️ NOT A SECOND CHORD READ: `modifiers` is the same value the old
            // `ArrangeClickIntent.intent(for:)` line consumed, now read once
            // inside the resolver. The two note arms and the plain-empty arm are
            // byte-equivalent to what shipped; only the ⌘-on-empty arm is new,
            // and it lands where NOTHING happened before.
            switch PianoRollGridPress.release(noteID: id, modifiers: modifiers) {
            case .selectOnly(let noteID):
                model.selectOnly(noteID)
            case .toggle(let noteID):
                model.toggle(noteID)
            case .deselect:
                // A press that never travelled `dragSlop` is still a CLICK, so
                // an empty-grid release clears — byte-identically to pre-ek-1.
                model.clearSelection()
            case .positionPlayhead:
                // ⭐ THE ONE SIDE EFFECT, AND IT IS THE SHIPPED ONE. `onSeek` is
                // the roll's documented single route to the transport; a direct
                // store call here would give this view two ways to move the
                // playhead and break the store-free rule the `onCommit`
                // precedent holds it to. NO `commit(` — placing the playhead
                // edits nothing, so it owes the undo journal nothing.
                // m25-o-2 — ⌥ bypasses the snap here too, so the ⌘-click and the
                // line drag beside it obey ONE rule. A click that snapped while
                // the drag two pixels away did not would be the same split the
                // user's ruling closed between the roll and the arrange.
                onSeek(PianoRollPlayhead.projectBeat(
                    localBeat: placementLocalBeat(atContentX: point.x,
                                                  snapBypassed: snapBypassHeld),
                    clipStartBeat: clip.startBeat,
                    lengthBeats: clip.lengthBeats))
            case .doNothing:
                break
            }
        case .marquee(let bandOrigin, let base, let additive):
            // The band's OWN origin (frozen at promotion), not the parameter:
            // they are the same point for a live drag, and the frozen one is the
            // only correct answer if they ever diverge.
            endMarquee(origin: bandOrigin, at: point, base: base, additive: additive)
        case .none:
            break
        case .cancelled:
            break   // external reseed swallowed this gesture (m18-i) — no commit
        }
        didMove = false
        marqueeBand = nil
        // m23-d: EVERY exit silences the audition — including `.cancelled`, the
        // m18-i external reseed that swallows the gesture without an
        // `onEnded`-shaped end. A branch that forgot this is exactly how a stuck
        // note ships.
        onAudition([], 0)
    }

    /// Which notes THIS ending gesture may grow the clip for (m25-f-3).
    ///
    /// ⚠️ **A SET OF IDS, NEVER "EXTEND TO FIT", and the reason is on the store
    /// verb**: `setClipNotes` receives the roll's WHOLE draft, which can already
    /// hold legal-but-latent notes far past the end (m18-f — authored by an AI,
    /// a paste, or an earlier trim). Only the notes the gesture just touched may
    /// move the clip's edge, or nudging one note at bar 2 would resurrect a
    /// forgotten note at bar 20 and stretch the clip to it.
    ///
    /// ⚠️⚠️ **AND "TOUCHED" IS NOT ENOUGH — IT MUST ALSO HAVE STARTED AUDIBLE.**
    /// A rigid group drag moves the WHOLE selection, so a ⌘A + one-16th nudge
    /// "touches" any latent note in the clip and would drag the clip's end out
    /// to it. That is the very surprise the id set exists to prevent, arriving
    /// through a different door. Both branches below therefore ask the same
    /// question — *was this note's onset inside the clip before the gesture?* —
    /// and a note that was already silent stays latent, exactly as m18-f
    /// promises. `moveIDsStartingAudible` carries the move's captured baseline;
    /// a resize never moves an onset, so its current onset IS its baseline.
    ///
    /// **RESIZE IS INCLUDED, and that is a decision.** m25-a justified
    /// `commit`'s empty default with *"DELETE and the velocity lane cannot push
    /// a note past the clip end, so neither should be able to grow the clip"* —
    /// and dragging a note's right handle plainly CAN, so the same reasoning
    /// puts it in. It is also the safe direction: a resize never moves the
    /// ONSET, so `ClipAutoExtend.extendedLength`'s strict-onset audibility test
    /// is already satisfied and the grow can only ever be the tail the user is
    /// actively dragging.
    ///
    /// A resize names ONLY the note being resized, never the selection: the
    /// other selected notes did not move, and m25-a's rule is that a stationary
    /// note must not move the clip's edge.
    ///
    /// ⚠️ ONE CALL SITE, DELIBERATELY. `EditorSurfaceOwnershipSiteTests` pins
    /// the number of `commit(` occurrences in this file as its R6 false-engage
    /// guard; splitting this switch across two `commit(` calls would have moved
    /// that count for a reason that has nothing to do with engagement. Deciding
    /// the id SET here and committing once keeps the pin measuring what it was
    /// built to measure.
    private func autoExtendIDs(for drag: ActiveDrag) -> Set<UUID> {
        switch drag {
        case .move: return model.moveIDsStartingAudible()
        // m25-g — a group STRETCH is the one gesture on this surface whose whole
        // purpose can be to push notes past the clip end, so it is the strongest
        // case for auto-extend there is. It asks the SAME question the other two
        // do — *was this note audible before the gesture?* — through the scale's
        // own captured baseline, so a ⌘A stretch still cannot drag the clip's
        // edge out to a latent note at bar 20. How far the clip may then grow
        // stays `ClipAutoExtend`'s decision, not this file's.
        case .groupScale: return model.scaleIDsStartingAudible()
        case .resize(let id):
            guard let note = model.draft.first(where: { $0.id == id }),
                  note.startBeat < model.clipLengthBeats else { return [] }
            return [id]
        // m25-o-2 — a playhead scrub extends nothing: it moves the transport,
        // which is not an edit and cannot make a note audible. It never reaches
        // here anyway (`endGesture` handles `.playheadDrag` in its own arm,
        // before the auto-extend branch), and it is listed explicitly rather
        // than folded into a `default` so a future gesture cannot inherit
        // "extends nothing" by silence.
        case .none, .click, .marquee, .playheadDrag, .cancelled: return []
        }
    }

    /// Distinct pitches of the current selection, ascending (m23-d) — the set the
    /// audition should be sounding right now.
    private var selectedPitches: [Int] {
        Array(Set(model.draft.filter { model.isSelected($0.id) }.map(\.pitch))).sorted()
    }

    /// Velocity of the LOWEST selected note — a drag sounds the way the note it
    /// carries will actually sound (m23-d).
    private var anchorVelocity: Int {
        model.draft.filter { model.isSelected($0.id) }
            .min { ($0.pitch, $0.startBeat) < ($1.pitch, $1.startBeat) }?.velocity
            ?? AuditionController.defaultVelocity
    }

    // MARK: - Velocity lane (Pro)

    private var velocitySection: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("VEL")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: Self.keyboardWidth, height: VelocityLane.height, alignment: .center)
            // The velocity lane has its OWN horizontal scroller, so follow has to
            // move it too (m23-c2): a page turn that moved only the grid would put
            // the grid's playhead in frame and the velocity lane's off-screen —
            // exactly the two-bands-disagreeing defect m23-c1 closed. Same target,
            // same nonce, its own marker.
            ScrollViewReader { velocityProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // `{ commit() }`, not a bare `commit`: Swift drops default
                    // arguments when a method is used as a function VALUE, so
                    // since m25-a gave `commit` an `extendToCover:` default the
                    // bare reference has type `(Set<UUID>) -> Void` and no
                    // longer converts to this lane's `() -> Void`.
                    VelocityLane(model: model, noteColor: noteColor,
                                 onCommit: { commit() })
                        // Width-identical with the note grid (same beat→x space),
                        // so the m18-f viewport extension rides along.
                        .frame(width: gridDrawnWidth)
                        // The playhead continues through the velocity lane so the eye
                        // tracks it across both editors (m10-e). Same content x + scale
                        // as the grid, so it lines up.
                        .overlay(alignment: .topLeading) { velocityPlayhead }
                        .overlay(alignment: .topLeading) {
                            followMarker(Self.velocityFollowMarkerID)
                        }
                }
                .onChange(of: followNonce) { _, _ in
                    velocityProxy.scrollTo(Self.velocityFollowMarkerID, anchor: .leading)
                    Task { @MainActor in
                        velocityProxy.scrollTo(Self.velocityFollowMarkerID, anchor: .leading)
                    }
                }
            }
        }
        .frame(height: VelocityLane.height)
        // The off-clip cue continues through the velocity lane for the same
        // reason the line does (m23-c1): if only one band carried it, the two
        // bands would disagree about where the transport is. Same builder, same
        // `bandViewportWidth`, so both edges land at the same x as the grid's.
        .overlay(alignment: .topLeading) { offClipCueBand(topInset: 6) }
    }

    /// The playhead line inside the velocity lane content (beta m10-e) — same cyan
    /// glowing hairline as the grid, spanning the lane height.
    @ViewBuilder
    private var velocityPlayhead: some View {
        if let x = PianoRollPlayhead.lineX(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat) {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 1.5, height: VelocityLane.height)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Controller strip (Pro, m16-b4)

    /// The Pro controller strip directly under the velocity lane — bend, mod,
    /// sustain, expression, pressure, and any CC as a stepped value line. Thin over
    /// `ControllerStripModel`; commits through `onCommitControllerLane`.
    private var controllerSection: some View {
        ControllerLaneStrip(
            model: controllerModel,
            accent: noteColor,
            snap: effectiveSnap,
            drawnWidth: controllerDrawnWidth,
            // m23-c2: the strip has no playhead of its own, but it must stay
            // horizontally aligned with the notes above it through a page turn.
            followTargetX: followTargetX,
            followNonce: followNonce,
            onCommit: commitControllerLane
        )
    }

    /// Commits the visible controller lane and reseeds the strip model from the
    /// updated clip (canonicalized stored lanes; keeps chips + selection live).
    private func commitControllerLane() {
        // m23-al R7 — and it is a SEPARATE funnel on purpose. The controller strip
        // does NOT go through `commit()`: `ControllerLaneStrip` carries its own
        // `onCommit` (`ControllerLaneStrip.swift:36`, fired at `:354`), threaded
        // here. Dropping this as "already covered by R6" would mean editing a CC
        // lane never engages the roll.
        //
        // NARROWED CLAIM, stated rather than rounded up: a controller-lane drag
        // that ends with `didEdit == false` does not commit and therefore does not
        // engage. Accepted — it changed nothing, and the alternative is editing a
        // child view to report a gesture that had no effect.
        onEngage()
        guard let type = controllerModel.selectedType else { return }
        let points = controllerModel.buildSubmission()
        if let updated = onCommitControllerLane(type, points) {
            controllerModel.load(lanes: updated.controllerLanes, clipLengthBeats: updated.lengthBeats)
        }
    }
}

/// The piano-roll note grid (black-key rows, beat/bar lines, out-of-clip shade,
/// notes) as its own Canvas view. Extracted from `PianoRollView` so its inputs
/// are closure-free and tick-stable: a transport tick that re-evaluates the
/// parent leaves this value equal, so SwiftUI skips it and the draw closure never
/// re-runs on playback (only note/snap/color edits invalidate it). Redraw is
/// still per-interaction, never per-frame (docs/DESIGN-LANGUAGE.md "Meters").
private struct PianoRollGrid: View {
    var model: PianoRollModel
    var beatsPerBar: Int
    var snap: SnapResolution
    /// The note tint as its `0xRRGGBB` literal, NOT as a `Color` — the pitch
    /// labels (m25-i) need the fill's luminance, and a `Color` cannot be
    /// inspected without a main-actor `NSColor` round-trip. The fill colour is
    /// derived from this, so there is one number, not two.
    var noteTintHex: UInt32
    var noteColor: Color { Color(hex: noteTintHex) }

    /// A value snapshot of everything the renderer needs, taken on the main actor
    /// before the closure runs. All fields are Sendable so the `@Sendable` Canvas
    /// closure captures only plain values — never `model` or `self` (CANVAS
    /// CONTRACT, m16-a; the pitch/beat mappings are affine and reproduced inline).
    private struct GridSnapshot {
        var rowHeight: CGFloat
        var pixelsPerBeat: CGFloat
        var clipLengthBeats: Double
        var draft: [MIDINote]
        var selectedIDs: Set<UUID>
        var beatsPerBar: Int
        var snapStep: Double
        var noteColor: Color
        /// The SAME tint as `noteColor`, in the form the pitch-label ink policy
        /// reasons in (m25-i). Both come from ONE hex literal in `DAWTheme`, so
        /// the ink can never be computed from a colour the fill isn't using.
        var noteTint: SRGBColor
    }

    /// `noteColor` and `noteTint` from ONE branch, never two agreeing ones.
    static func tintHex(isAI: Bool) -> UInt32 { isAI ? DAWTheme.aiHex : DAWTheme.playbackHex }

    /// What a note pill composites OVER: the grid panel, plus the black-key lane
    /// wash on accidental rows. The wash alpha is `blackKeyLaneAlpha` — the same
    /// constant `drawBlackKeyRows` paints with, not a copy of 0.22.
    ///
    /// ⚠️ `nonisolated`, and it is the CANVAS CONTRACT (m16-a) rather than
    /// tidiness: a `View`'s members are main-actor-isolated by default, and both
    /// of these are read from inside the `@Sendable` renderer. Written without
    /// it, both compiled with a warning that names the defect exactly ("main
    /// actor-isolated … referenced from a nonisolated context") — the annotation
    /// is what keeps the renderer's value-only capture discipline enforceable by
    /// the compiler instead of by habit.
    private nonisolated static func rowBackdrop(isBlackKeyRow: Bool) -> SRGBColor {
        let panel = SRGBColor(hex: DAWTheme.panelHex)
        guard isBlackKeyRow else { return panel }
        return SRGBColor(hex: 0x000000).blended(over: panel, alpha: blackKeyLaneAlpha)
    }

    /// Black-key lane wash. ONE home: the row fill and the ink policy that has to
    /// know how dark that row is read the same number.
    private nonisolated static let blackKeyLaneAlpha: Double = 0.22

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let s = GridSnapshot(
            rowHeight: model.rowHeight,
            pixelsPerBeat: model.pixelsPerBeat,
            clipLengthBeats: model.clipLengthBeats,
            draft: model.draft,
            selectedIDs: model.selection,
            beatsPerBar: beatsPerBar,
            snapStep: snap.beats ?? 1,
            noteColor: noteColor,
            noteTint: SRGBColor(hex: noteTintHex))
        return Canvas { @Sendable context, size in
            Self.drawBlackKeyRows(&context, size: size, s: s)
            Self.drawGridLines(&context, size: size, s: s)
            Self.drawOutOfClipShade(&context, size: size, s: s)
            Self.drawNotes(&context, s: s)
        }
    }

    private nonisolated static func drawBlackKeyRows(_ context: inout GraphicsContext, size: CGSize, s: GridSnapshot) {
        for pitch in 0..<PianoRollModel.pitchCount where KeyboardSidebar.isBlackKey(pitch) {
            let y = CGFloat(PianoRollModel.pitchCount - 1 - pitch) * s.rowHeight
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: s.rowHeight)),
                with: .color(Color.black.opacity(blackKeyLaneAlpha))
            )
        }
        // Octave separators.
        for pitch in stride(from: 0, through: PianoRollModel.pitchCount - 1, by: 12) {
            let y = CGFloat(PianoRollModel.pitchCount - 1 - pitch) * s.rowHeight
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                with: .color(Color.white.opacity(0.10))
            )
        }
    }

    /// Grid lines follow the snap, density-adapted to the zoom (m21-c): bar
    /// lines (`gridEmphasis`) and beat lines (`hairline`) always draw — the
    /// survey grid — while SUB-beat division hairlines fade with zoom
    /// (`PianoRollZoom.subBeatLineAlpha`) so a 1/64 or triplet grid appears
    /// only once it has room to be useful, never as visual soup (the arrange
    /// m17-b "grid density adapts, never forks" rule). Division x positions
    /// are exact rationals (`beat + d/divisions`), so triplet lines never
    /// accumulate float drift; when the fade bottoms out the sub-division loop
    /// is skipped entirely (no invisible-line work).
    private nonisolated static func drawGridLines(_ context: inout GraphicsContext, size: CGSize, s: GridSnapshot) {
        let beatsShown = Int((size.width / s.pixelsPerBeat).rounded(.up))
        let step = s.snapStep
        let barStride = max(1, s.beatsPerBar)
        // Coarser-than-beat snaps (Bar) keep drawing only their own lines —
        // the pre-zoom behavior.
        if step >= 1 {
            let stride = max(1, Int(step.rounded()))
            var b = 0
            while b <= beatsShown {
                let x = CGFloat(b) * s.pixelsPerBeat
                let color = b % barStride == 0 ? DAWTheme.gridEmphasis : DAWTheme.hairline
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
                b += stride
            }
            return
        }
        let divisions = PianoRollZoom.divisionsPerBeat(step: step)
        let alpha = PianoRollZoom.subBeatLineAlpha(step: step, pixelsPerBeat: s.pixelsPerBeat)
        let subColor = DAWTheme.hairline.opacity(0.5 * alpha)
        for b in 0...beatsShown {
            let x = CGFloat(b) * s.pixelsPerBeat
            let color = b % barStride == 0 ? DAWTheme.gridEmphasis : DAWTheme.hairline
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
            guard alpha > 0, b < beatsShown, divisions > 1 else { continue }
            for d in 1..<divisions {
                let dx = (CGFloat(b) + CGFloat(d) / CGFloat(divisions)) * s.pixelsPerBeat
                context.fill(Path(CGRect(x: dx, y: 0, width: 1, height: size.height)), with: .color(subColor))
            }
        }
    }

    private nonisolated static func drawOutOfClipShade(_ context: inout GraphicsContext, size: CGSize, s: GridSnapshot) {
        let clipX = CGFloat(s.clipLengthBeats) * s.pixelsPerBeat
        guard clipX < size.width else { return }
        context.fill(
            Path(CGRect(x: clipX, y: 0, width: size.width - clipX, height: size.height)),
            with: .color(Color.black.opacity(0.28))
        )
        // 1 pt neutral clip-end hairline (m19-g — the m18-e CTRL-strip boundary
        // grammar, now in all three bands at the same x): the latent region
        // reads as a deliberate boundary, not a rendering seam. gridEmphasis is
        // the grid's own bar-line chrome — no accent, no glow (a boundary is
        // chrome, not state). Drawn over the shade; where the clip end lands on
        // a bar line the two same-color lines merge — never a second visible
        // hairline.
        context.fill(
            Path(CGRect(x: clipX - 0.5, y: 0, width: 1, height: size.height)),
            with: .color(DAWTheme.gridEmphasis)
        )
    }

    /// Note pills, split at the clip boundary (m19-g ghost treatment —
    /// DESIGN-LANGUAGE "Controller strips"): a note whose onset the engine
    /// plays takes the full neon treatment; latent data — an onset at/past the
    /// clip end, or the truncated tail of a note crossing it — draws as a dim
    /// flat core with NO bloom (glow is earned; inert data earns none, the
    /// m18-e ghost grammar). The split comes from the model's engine-honest
    /// `playableEndBeat` — ONE boundary definition, never view beat math.
    private nonisolated static func drawNotes(_ context: inout GraphicsContext, s: GridSnapshot) {
        // ONE text layout per DRAW for the pitch labels (m25-i), not one per
        // note: the face is monospaced, so every name's width is its glyph count
        // times a single advance. A 400-note clip therefore costs ONE resolve
        // here plus one draw per name that actually fits — the labels add no
        // per-note layout to a path that already redraws on every drag frame.
        let probe = context.resolve(
            Text("0000").font(.system(size: PianoRollNoteLabel.fontSize, weight: .medium,
                                      design: .monospaced))
        )
        let probeSize = probe.measure(in: CGSize(width: 1000, height: 100))
        let glyph = CGSize(width: probeSize.width / 4, height: probeSize.height)
        for note in s.draft {
            // ONE producer of the note rect (m23-ek-1): the same `noteRect` a
            // CLICK hit-tests and a BAND intersects, inset HERE at the call site
            // for the pill. Hand-rolling the arithmetic again — as this loop did
            // until m23-ek-1 — keeps a third copy of `max(3, …)` alive, and it
            // is the copy a zoom change is most likely to touch.
            let rect = PianoRollModel.noteRect(
                note, rowHeight: s.rowHeight, pixelsPerBeat: s.pixelsPerBeat
            ).insetBy(dx: 0.5, dy: 1.5)
            let selected = s.selectedIDs.contains(note.id)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            guard let playableEnd = PianoRollModel.playableEndBeat(
                of: note, clipLengthBeats: s.clipLengthBeats) else {
                // Onset at/past the clip end — the engine never sounds it.
                drawGhostPill(&context, path: path, selected: selected, s: s)
                continue
            }
            if playableEnd >= note.endBeat {
                drawLitPill(&context, rect: rect, path: path, note: note, selected: selected, s: s)
                drawNoteLabel(&context, rect: rect, note: note, selected: selected,
                              visibleWidth: rect.width, glyph: glyph, s: s)
            } else {
                // Partial overhang: the engine truncates the note-off at the
                // clip end (`min(endBeat, clipLength)`), so the body is lit to
                // the boundary and the silent tail ghosts past it. Clipped
                // copies of the context split the one rounded pill at exactly
                // the boundary x (the bloom stays inside the lit side — glow
                // never spills into latent space).
                let boundaryX = CGFloat(playableEnd) * s.pixelsPerBeat
                let pad: CGFloat = 4
                var lit = context
                lit.clip(to: Path(CGRect(x: rect.minX - pad, y: rect.minY - pad,
                                         width: boundaryX - (rect.minX - pad),
                                         height: rect.height + pad * 2)))
                drawLitPill(&lit, rect: rect, path: path, note: note, selected: selected, s: s)
                // The label's budget is the LIT width, not the pill's width: the
                // context above is clipped at the boundary, so a name sized
                // against the full rect would be sliced by that clip — a
                // truncated pitch name, which is the one thing
                // `PianoRollNoteLabel` exists to prevent, arriving through
                // geometry instead of through text layout.
                drawNoteLabel(&lit, rect: rect, note: note, selected: selected,
                              visibleWidth: boundaryX - rect.minX, glyph: glyph, s: s)
                var ghost = context
                ghost.clip(to: Path(CGRect(x: boundaryX, y: rect.minY - pad,
                                           width: (rect.maxX + pad) - boundaryX,
                                           height: rect.height + pad * 2)))
                drawGhostPill(&ghost, path: path, selected: selected, s: s)
            }
        }
    }

    /// The full neon pill treatment (unchanged from pre-m19-g): velocity →
    /// fill opacity, selected = brighter + hairline + subtle bloom.
    /// The lit pill's fill opacity — velocity → alpha, selection → +0.2 clamped.
    ///
    /// ONE home (m25-i): the pitch label's ink polarity is decided from what this
    /// alpha composites to, so if the fill and the ink read two copies of this
    /// expression, a change to the velocity curve silently leaves the ink behind
    /// on a pill it can no longer be read on.
    private nonisolated static func litFillOpacity(velocity: Int, selected: Bool) -> Double {
        let opacity = 0.45 + 0.5 * (Double(velocity) / 127)
        return selected ? min(1, opacity + 0.2) : opacity
    }

    /// The pitch name ON the note block (m25-i) — the second half of "labels on
    /// every key AND on the notes themselves".
    ///
    /// Three decisions live here, each recorded where it is made:
    /// 1. **Lit pills only.** A ghost pill (an onset at/past the clip end, or the
    ///    tail of a note crossing it) is deliberately the least informative thing
    ///    the grid draws — flat, dim, velocity no longer modulating it, no bloom
    ///    (m19-g). A crisp name on one would be the BRIGHTEST thing about an
    ///    inert block, inverting that grammar. A partially-overhanging note still
    ///    gets exactly one name, on its lit body, because the split draws the lit
    ///    half first.
    /// 2. **Suppress, never truncate**, and never scale the type down — see
    ///    `PianoRollNoteLabel.fits`. `"C#4"` cut to `"C#"` is a valid, DIFFERENT
    ///    pitch name, so truncation here invents a plausible wrong answer.
    /// 3. **Both densities.** A pitch name is content, not edit chrome — the
    ///    same call the MIDI note-map and the empty-lane hint make — and Rule 6
    ///    (the beginner test) points the same way: the reader who most needs to
    ///    know that block is an F# is the one in Simple mode.
    private nonisolated static func drawNoteLabel(_ context: inout GraphicsContext, rect: CGRect,
                                                  note: MIDINote, selected: Bool,
                                                  visibleWidth: CGFloat, glyph: CGSize,
                                                  s: GridSnapshot) {
        // `Fundamental.noteName` — the repo's ONE scientific-pitch name, the same
        // one the gutter key beside this note is labelled with, so a note and its
        // key can never disagree about what the pitch is called.
        let name = Fundamental.noteName(midiNote: note.pitch)
        let size = CGSize(width: PianoRollNoteLabel.width(glyphCount: name.count, advance: glyph.width),
                          height: glyph.height)
        guard PianoRollNoteLabel.fits(labelSize: size, pillWidth: visibleWidth,
                                      pillHeight: rect.height) else { return }
        // DUAL INK, per pill: the polarity comes from what THIS pill composites
        // to over THIS row, never from a constant and never from velocity (the
        // two tints flip at different velocities — cyan ≈ 8, violet ≈ 56).
        let dark = NotePillInk.prefersDarkInk(
            tint: s.noteTint,
            alpha: litFillOpacity(velocity: note.velocity, selected: selected),
            backdrop: rowBackdrop(isBlackKeyRow: KeyboardSidebar.isBlackKey(note.pitch)))
        let label = Text(name)
            .font(.system(size: PianoRollNoteLabel.fontSize, weight: .medium, design: .monospaced))
            .foregroundColor(dark ? DAWTheme.noteInkOnLight : DAWTheme.noteInkOnDark)
        context.draw(label,
                     at: CGPoint(x: rect.minX + PianoRollNoteLabel.leadingInset, y: rect.midY),
                     anchor: .leading)
    }

    private nonisolated static func drawLitPill(_ context: inout GraphicsContext, rect: CGRect, path: Path,
                                                note: MIDINote, selected: Bool, s: GridSnapshot) {
        let opacity = litFillOpacity(velocity: note.velocity, selected: selected)
        if selected {
            // Subtle bloom behind a selected note.
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                with: .color(s.noteColor.opacity(0.28))
            )
        }
        context.fill(path, with: .color(s.noteColor.opacity(opacity)))
        context.stroke(
            path,
            with: .color(selected ? DAWTheme.textPrimary.opacity(0.9) : s.noteColor.opacity(0.9)),
            lineWidth: selected ? 1 : 0.5
        )
    }

    /// The m19-g ghost pill: a flat dim core (fill 0.35 / hairline 0.45 — the
    /// m18-e ghost-handle ratios) with velocity NO LONGER modulating opacity
    /// (latent data reads uniformly inert). Selection keeps its neutral
    /// hairline stroke — a selected ghost must still read selected (editing is
    /// boundary-blind) — but never the bloom: no glow layers on latent data.
    private nonisolated static func drawGhostPill(_ context: inout GraphicsContext, path: Path,
                                                  selected: Bool, s: GridSnapshot) {
        context.fill(path, with: .color(s.noteColor.opacity(0.35)))
        context.stroke(
            path,
            with: .color(selected ? DAWTheme.textPrimary.opacity(0.9) : s.noteColor.opacity(0.45)),
            lineWidth: selected ? 1 : 0.5
        )
    }
}
