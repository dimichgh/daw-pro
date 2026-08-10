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
    var onCommit: ([MIDINote]) -> Void
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
    var onPasteNotes: ([MIDINote]) -> Void
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
    @State private var snap: SnapResolution = .beat
    @State private var activeDrag: ActiveDrag = .none
    @State private var didMove = false
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
    /// The zoom scale captured on the first pinch tick (m21-c) — each tick
    /// rescales off the gesture-START value because `MagnifyGesture`'s
    /// magnification is cumulative (the arrange `PinchState` rule, minus the
    /// anchor math: the roll's plain SwiftUI scroller owns its own offset).
    @State private var pinchStartPPB: CGFloat?
    /// A transient inline reason shown when the delete-bar button is pressed
    /// while it can't act (m21-c bar-ops honesty) — the m17-c refusal-bubble
    /// idiom: amber, verbatim prose, auto-clearing.
    @State private var barOpsNotice: String?
    @State private var barOpsNoticeTask: Task<Void, Never>?
    /// The content x follow last asked every band to put at its leading edge
    /// (m23-c2), plus the nonce that makes a repeat of the same x still apply. The
    /// bands' `ScrollViewReader`s watch the nonce; the markers size off the x.
    @State private var followTargetX: CGFloat = 0
    @State private var followNonce = 0
    @FocusState private var isFocused: Bool

    private static let keyboardWidth: CGFloat = 54
    /// Height of the frozen scrub strip pinned to the top of the note grid.
    private static let scrubStripHeight: CGFloat = 18
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

    init(clip: Clip, beatsPerBar: Int, positionBeats: Double, isPlaying: Bool,
         densityStore: PanelDensityStore,
         layout: PanelLayoutStore, follow: FollowPlayheadModel,
         onCommit: @escaping ([MIDINote]) -> Void, onSeek: @escaping (Double) -> Void,
         onDeleteTimeRange: @escaping (_ startBeat: Double, _ lengthBeats: Double) -> Clip?,
         onInsertTimeRange: @escaping (_ atBeat: Double, _ lengthBeats: Double) -> Clip?,
         onOpenQuantize: @escaping () -> Void,
         onCommitControllerLane: @escaping (_ type: MIDIControllerType, _ points: [MIDIControllerPoint]) -> Clip?,
         onCopyNotes: @escaping ([MIDINote]) -> Void = { _ in },
         onCutNotes: @escaping (_ copied: [MIDINote], _ remaining: [MIDINote]) -> Bool
             = { _, _ in false },
         onPasteNotes: @escaping ([MIDINote]) -> Void = { _ in },
         clipboardNotes: [MIDINote] = [],
         onClose: @escaping () -> Void,
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
        self.layout = layout
        self.follow = follow
        self.onCommit = onCommit
        self.onSeek = onSeek
        self.onDeleteTimeRange = onDeleteTimeRange
        self.onInsertTimeRange = onInsertTimeRange
        self.onOpenQuantize = onOpenQuantize
        self.onCommitControllerLane = onCommitControllerLane
        self.onCopyNotes = onCopyNotes
        self.onCutNotes = onCutNotes
        self.onPasteNotes = onPasteNotes
        self.clipboardNotes = clipboardNotes
        self.onClose = onClose
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

    /// Simple mode locks snapping to whole beats; Pro honors the picker.
    private var effectiveSnap: SnapResolution { mode == .simple ? .beat : snap }

    /// Violet whenever the clip is AI-touched, else playback cyan.
    private var noteColor: Color { clip.isAIGenerated ? DAWTheme.ai : DAWTheme.playback }

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
        .onChange(of: noteSelection.stageNonce) { _, _ in
            if noteSelection.stagedSelectAll {
                model.selection = Set(model.draft.map(\.id))
            } else {
                model.clearSelection()
            }
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
        }
        // m21-c: ONE persisted zoom value (`panelLayout.pianoRollPPB`) feeds
        // every band's beat→x mapping — the note grid + velocity lane via
        // `model`, the controller strip via its own model — so all three
        // rescale together and never drift.
        .onChange(of: layout.pianoRollPPB, initial: true) { _, ppb in
            model.pixelsPerBeat = ppb
            controllerModel.pixelsPerBeat = ppb
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
    private var playheadLineX: CGFloat? {
        PianoRollPlayhead.lineX(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat)
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
    private func commit() {
        onEngage()
        onCommit(model.buildSubmission())
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
            // ⚠️ SNAP THE ANCHOR **ONCE**, THEN TRANSLATE RIGIDLY. Snapping each
            // pasted note's absolute start instead WELDS notes sitting at
            // different sub-grid phases — a swung or triplet figure pasted onto a
            // 1/16 grid would come out straight, silently. That is the m23-g2
            // defect verbatim: snapping is a property of the GESTURE, not of each
            // element. With snap off, `model.snap` passes through (floored at 0),
            // so this same path is correct there too.
            let anchor = model.snap(
                beat: PasteAnchorPolicy.noteLocalAnchor(
                    playheadProjectBeat: positionBeats,
                    clipStartBeat: clip.startBeat,
                    clipLengthBeats: clip.lengthBeats),
                resolution: effectiveSnap)
            let pasted = PasteAnchorPolicy.translatedNotes(payload, toAnchor: anchor)
            guard !pasted.isEmpty else { return }
            onEngage()   // m23-al R9 — clipboard paste
            // Canonically ordered so the store's own ordering matches and
            // `needsReseed` stays false — which is what keeps the selection below
            // from being wiped by the reseed the commit triggers.
            model.draft = MIDINote.canonicallyOrdered(model.draft + pasted)
            // The pasted notes become the selection, so the user can drag them
            // immediately (the double-tap-add precedent, `model.selectOnly`).
            model.selection = Set(pasted.map(\.id))
            onPasteNotes(model.buildSubmission())
        }
    }

    /// The draft notes the user has selected, in draft order.
    private func selectedNotes() -> [MIDINote] {
        model.draft.filter { model.selection.contains($0.id) }
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
            barOpsCluster
                .explainable(.pianoRollBarOps)
            if editorMode == .notes {
                controllerLaneSummaryChip
            }
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

    /// The live pinch (m21-c): magnification is cumulative, so every tick
    /// rescales off the gesture-START scale (the arrange `PinchState` rule).
    /// No anchor RE-PIN here: a pinch rescales the bands but does not hold the
    /// beat under the cursor at a fixed screen x the way the arrange's zoom does.
    ///
    /// That is a scope choice, not a platform limit — corrected m23-c2, because
    /// this comment used to say the arrange "needed an AppKit bridge for that" and
    /// that bridge was never built: the arrange's programmatic scroll is plain
    /// SwiftUI (`ScrollViewReader` + a layout-real marker), and this view now uses
    /// the same idiom for follow. An anchor re-pin here is strictly harder than
    /// follow's scroll-into-view (it must land mid-gesture, against content that is
    /// rescaling under it), and it remains unbuilt for that reason alone.
    private var gridPinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                onEngage()   // m23-al R3 — pinch-zoom the roll
                if pinchStartPPB == nil { pinchStartPPB = layout.pianoRollPPB }
                guard let start = pinchStartPPB else { return }
                layout.setPianoRollPPB(PianoRollZoom.clamp(start * value.magnification))
            }
            .onEnded { _ in pinchStartPPB = nil }
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
            Text("SNAP: \(snap.label)")
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
                                  snap: effectiveSnap, noteColor: noteColor)
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
                        .overlay(alignment: .topLeading) {
                            followMarker(Self.gridFollowMarkerID)
                        }
                        .background { gridScrollReader }
                        // Pointer affordances (docs/DESIGN-LANGUAGE.md): a note body
                        // grabs, its right-edge resize handle (Pro) resizes, empty
                        // grid keeps the arrow. Mirrors `gridDrag`'s hit routing.
                        .hoverCursor(resolve: gridCursor)
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
                                commit()
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
        }
        .defaultScrollAnchor(.center)   // open near middle C, full 0-127 scrollable
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

    /// The frozen scrub band: a transparent strip over the top of the grid (past
    /// the keyboard gutter) whose drag SEEKS the transport. Click jumps, drag
    /// scrubs continuously — free (unsnapped), the deliberate pro default. Works
    /// while playing and stopped (mid-play seek is supported engine behavior). The
    /// `resizeLeftRight` cursor advertises it (a horizontal position drag), held
    /// through the drag by `DragCursor` (docs/DESIGN-LANGUAGE.md pointer family).
    private var scrubStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.keyboardWidth)   // gutter — no scrub here
            Color.clear
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .hoverCursor(.resizeLeftRight)
                .gesture(scrubDrag)
                .help("Scrub — drag to move the playhead")
        }
        .frame(height: Self.scrubStripHeight)
    }

    private var scrubDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                onEngage()   // m23-al R2 — ruler scrub
                DragCursor.set(.resizeLeftRight)
                // Strip-local x=0 is the grid's left edge (unscrolled); add the
                // live scroll offset to recover the content beat.
                let contentX = value.location.x + gridScrollX
                onSeek(PianoRollPlayhead.scrubProjectBeat(
                    localX: contentX, clipStartBeat: clip.startBeat,
                    lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat))
            }
            .onEnded { _ in DragCursor.clear() }
    }

    // MARK: - Grid gesture (move / resize / click-select)

    /// Rest cursor over the note grid: mirror the `gridDrag` hit routing so the
    /// hover cue matches what a press would do (a note body grabs, its Pro resize
    /// handle resizes, empty grid keeps the arrow — double-click-to-add doesn't
    /// warrant a crosshair on a single hover).
    private func gridCursor(at point: CGPoint) -> CursorKind? {
        guard let hit = model.hitTest(point) else { return nil }
        let zone: NoteZone = (hit.zone == .resizeHandle && mode == .pro) ? .resizeHandle : .body
        return CursorAffordance.forNoteZone(zone)
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
                    case .resize: DragCursor.set(.resizeLeftRight)
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
        if let hit, !toggling, hit.zone == .resizeHandle, mode == .pro {
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
        // The live pointer's OWN quantities, passed through unchanged: no
        // geometry a real drag depends on is recomputed. The one thing that did
        // change is WHERE `.current` is read — it used to be evaluated inside the
        // `.click, .marquee` branch and is now evaluated on every tick, including
        // `.move` and `.resize`, where it goes unused. A modifier-flags read is
        // side-effect-free, so this is a cost, not a behaviour change.
        advanceGesture(translation: value.translation, location: value.location,
                       origin: value.startLocation, modifiers: .current)
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
        case .resize(let id):
            model.resizeNote(id: id, toEndBeat: model.beat(forX: location.x), resolution: effectiveSnap)
            if abs(translation.width) > PianoRollMarquee.moveCommitSlop { didMove = true }
        case .click, .marquee:
            // m23-ek-1: the ONE home for promote-then-apply. The live gesture and
            // the staging seam both arrive here, so the threshold and the band
            // cannot be spelled twice.
            advanceMarquee(origin: origin, to: location, modifiers: modifiers)
        case .none, .cancelled:
            break
        }
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
        case .move, .resize, .none, .cancelled:
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
        switch outgoing {
        case .move, .resize:
            if didMove { commit() }   // else it was a plain click; selection already set
        case .click(let id):
            let toggling = ArrangeClickIntent.intent(for: modifiers) == .toggle
            if let id {
                if toggling { model.toggle(id) } else { model.selectOnly(id) }
            } else if !toggling {
                // A press that never travelled `dragSlop` is still a CLICK, so
                // an empty-grid release clears — byte-identically to pre-ek-1.
                model.clearSelection()
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
                    VelocityLane(model: model, noteColor: noteColor, onCommit: commit)
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
    var noteColor: Color

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
    }

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
            noteColor: noteColor)
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
                with: .color(Color.black.opacity(0.22))
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
    private nonisolated static func drawLitPill(_ context: inout GraphicsContext, rect: CGRect, path: Path,
                                                note: MIDINote, selected: Bool, s: GridSnapshot) {
        let velocity = Double(note.velocity) / 127
        let opacity = 0.45 + 0.5 * velocity
        if selected {
            // Subtle bloom behind a selected note.
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                with: .color(s.noteColor.opacity(0.28))
            )
        }
        context.fill(path, with: .color(s.noteColor.opacity(selected ? min(1, opacity + 0.2) : opacity)))
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
