import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Which slice of the arrange surface a `TimelineLanesView` renders (m13-g,
/// ruler-block pinning). `.full` is the legacy single-view composition (previews /
/// headless callers); the live arrange splits into a pinned `.ruler` block (loop /
/// marker / tempo lanes + bar numbers, above the shared vertical scroll) and the
/// scrolling `.lanes` body (clips / takes / automation / playhead) so the ruler
/// stays visible however deep you scroll — while the two stay HORIZONTALLY synced
/// (the `.lanes` instance reports its scroll offset, the `.ruler` mirrors it).
enum ArrangeContent: Equatable {
    /// Ruler + lanes in one horizontal scroll (the pre-m13-g behaviour).
    case full
    /// The pinned ruler block only — loop band, marker lane, tempo lane, bar
    /// numbers. No vertical scroll; horizontally offset to track the lanes.
    case ruler
    /// The scrolling lane content only — clips, take lanes, automation, playhead.
    /// Starts its lanes at y = 0 (the ruler is pinned separately).
    case lanes
}

// The `.lanes` → `.ruler` horizontal sync (m13-g) is a one-way mirror: the lane
// content's `minX` in the scroll coordinate space, negated, is the scroll
// distance, reported up through `onHScrollChange`. It was born as an
// `ArrangeHOffsetKey` PreferenceKey; m17-b (arrange zoom — the first feature
// that actually scrolls this axis) MEASURED that on current macOS the native
// ScrollView never re-delivers `.preference()` changes emitted from its content
// (only the initial default reached any listener, content-side included), while
// a content GeometryReader keeps re-evaluating with fresh geometry — so the
// mirror now reports via `.onChange` inside that GeometryReader (view-update
// machinery), same contract, working delivery. See `lanesBody`.

/// Arrange timeline: one horizontal lane per track (same order as the sidebar),
/// clips as rounded interactive blocks positioned by beats, a beat/bar grid, and
/// a glowing cyan playhead. Clips move/trim/split/fade under the snap grid and
/// audio clips draw a peak waveform (M5 i-d); a MIDI clip tap still opens the
/// piano roll (docs/DESIGN-LANGUAGE.md "Glass Cockpit"). A track whose automation
/// disclosure is open grows a breakpoint-editor row under its clip lane,
/// beat-aligned with the grid. The horizontal scale is the zoomable
/// `pixelsPerBeat` input (m17-b, 4…200, default 16) — EVERY beat↔x mapping in
/// this view derives from it, so the ruler block, lanes, gestures, and overlays
/// scale together; grid/label density adapts via `ArrangeZoom`.
struct TimelineLanesView: View {
    var tracks: [Track]
    var positionBeats: Double
    /// The arrange's clip selection (m23-g1): the selected SET plus the focus
    /// clip. Every block reads membership for its selected state and focus for
    /// its single-target editing affordances (see `ClipBlock.isFocused`).
    var selection: ArrangeSelection
    var onSelectClip: (Clip, ArrangeClickModifiers) -> Void
    /// Fires after the lanes have re-rendered with a CHANGED selection — the
    /// `debug.arrangeSelection` seam's "the view has run" signal (the
    /// `onDropHoverChange` contract, m23-e echo-seam law). Only the lane-bearing
    /// instance reports; the pinned `.ruler` block draws no clip blocks.
    var onSelectionRendered: (() -> Void)?
    /// Fires after the lanes have re-rendered with CHANGED clip geometry — the
    /// `debug.arrangeDrag` seam's "the view has run" signal (m23-g2). Separate
    /// from `onSelectionRendered` because a group move changes no selection.
    var onClipLayoutRendered: (() -> Void)?
    /// Tracks whose automation lane is expanded (shared with the sidebar via
    /// AppModel, so both columns grow the same row and stay aligned).
    var expandedTrackIDs: Set<UUID> = []
    /// Which lane each track is editing (trackID → laneID); absent = its first.
    var selectedLaneByTrack: [UUID: UUID] = [:]
    /// Submits an edited breakpoint array (wired to `setAutomationPoints`).
    var onCommitPoints: (_ trackID: UUID, _ laneID: UUID, _ points: [AutomationPoint]) -> Void = { _, _, _ in }
    /// m23-ai: where every automation lane editor below reports "I hold a
    /// breakpoint selection" so the arrange's ← / → nudge refuses instead of
    /// sliding the clip out from under the point being edited. Optional in type
    /// but WITHOUT a default, on purpose: a `nil` slipped in by omission would
    /// silently unguard the arrow keys, and this view has exactly one mount that
    /// must therefore state its answer (`waveformStore` above sets the same
    /// precedent for a dependency that must not be defaulted away).
    var automationPointSelection: AutomationPointSelectionBridge?

    // MARK: Clip editing (M5 i-d)

    /// Active grid snap for clip move/trim/split (arrange header picker).
    var snap: ClipSnap = .bar
    /// Seconds per beat at the current tempo — maps `startOffsetSeconds` to the
    /// waveform window.
    var secondsPerBeat: Double = 0.5
    /// Peak cache for audio-clip waveforms (off-main read, cached by URL).
    var waveformStore: WaveformStore
    /// The shared per-panel density store (docs/DESIGN-LANGUAGE.md "Panels"). The
    /// whole arrange workspace is ONE panel (`Self.panelID`): Simple locks the clip
    /// grid to Bar and suppresses the trim/fade/split/gain/stretch chrome AND their
    /// gesture entry points (an edge drag MOVES the clip, no dead hit-zone); Pro is
    /// today's full clip-edit layer. Threaded from ContentView like MixerView's, so
    /// `debug.panelDensity` reflects live.
    var densityStore: PanelDensityStore
    /// Global track-row height (beta m10-d), threaded from `PanelLayoutStore` so the
    /// timeline clip lanes and the sidebar track headers scale TOGETHER (both read
    /// the one store value). Defaults to the historical `Self.laneHeight` for
    /// previews / headless callers. Only the base clip lane scales — the automation
    /// row (`automationLaneHeight`) and take sub-rows (`takeLaneRowHeight`,
    /// `takeGroupHeaderHeight`) keep their own constants, so those sections compose
    /// on top of a taller/shorter clip lane without themselves resizing.
    var rowHeight: CGFloat = Self.laneHeight
    /// Arrange horizontal zoom (m17-b): pixels per beat, threaded from
    /// `PanelLayoutStore.arrangePPB` so the pinned `.ruler` block and the
    /// scrolling `.lanes` body scale in the SAME update (both instances read the
    /// one store value — the rowHeight discipline, horizontal axis). Every
    /// beat↔x mapping below derives from THIS value; nothing else may hardcode a
    /// scale. Defaults to the historical 16 for previews / headless callers.
    var pixelsPerBeat: CGFloat = Self.defaultPixelsPerBeat
    /// The lanes viewport WIDTH (m17-b), threaded from ContentView's geometry —
    /// used only by the empty-bars padding heuristic so the timeline surface
    /// still fills the viewport when zoomed far out on a short session. 0
    /// (previews / headless) falls back to the content-driven width.
    var availableWidth: CGFloat = 0
    /// Live pinch-zoom ticks (m17-b, MagnifyGesture on the lanes area): reports
    /// the pointer's CONTENT-space x at gesture start + the cumulative
    /// magnification; the AppModel owns the anchor math (`ArrangeZoom.PinchState`)
    /// and writes the scale + compensated scroll offset back down.
    var onPinchZoomChanged: ((_ anchorContentX: CGFloat, _ magnification: CGFloat) -> Void)? = nil
    var onPinchZoomEnded: (() -> Void)? = nil
    /// The shared-scroll viewport height (m10-j), threaded from ContentView's
    /// GeometryReader. The timeline fills it when the content is SHORT (so the glass
    /// panel doesn't shrink to its content and the column stays flush with the
    /// sidebar) and reports its natural `contentHeight` when TALL, letting the outer
    /// vertical ScrollView own the overflow. 0 (previews / headless callers, and the
    /// legacy non-shared-scroll path) falls back to the natural content height.
    var availableHeight: CGFloat = 0
    /// Clip edits — each wired to one of the five `ProjectStore` clip methods.
    /// A body drag reports the ANCHOR clip's drag-origin start plus the RAW,
    /// PRE-SNAP pointer translation, and gets back the ACHIEVED anchor start
    /// (m23-g2). It does NOT report a snapped target: snapping is a property of
    /// the gesture as a whole (the anchor snaps once, the selection translates
    /// rigidly), and a per-clip snapped target is exactly the shape that welds a
    /// group together — see `ArrangeGroupDrag`.
    var onMoveClip: (_ trackID: UUID, _ clip: Clip,
                     _ anchorOriginalStart: Double,
                     _ rawDragDeltaBeats: Double) -> Double = { _, _, s, _ in s }
    var onTrimClip: (_ trackID: UUID, _ clip: Clip, _ newStart: Double, _ newLength: Double) -> Void = { _, _, _, _ in }
    /// Fits a clip's length to its content (m21-d, Pro clip menu; wired to
    /// `ProjectStore.fitClipToContent` — MIDI: last note end, audio: remaining
    /// source duration).
    var onFitClipToContent: (_ trackID: UUID, _ clip: Clip) -> Void = { _, _ in }
    /// Removes a clip from the clip context menu (m23-cf). The `ClipDeleteCommand`
    /// says whether the whole arrange selection is the target or just this clip,
    /// and carries the exact title the user was shown — so the handler and the
    /// menu can never name different blast radii. Wired to
    /// `AppModel.deleteClipFromContextMenu`, which routes to the SAME
    /// `ProjectStore.removeClips` the DELETE key uses.
    var onDeleteClip: (_ clip: Clip, _ command: ClipDeleteCommand) -> Void = { _, _ in }
    var onSplitClip: (_ trackID: UUID, _ clip: Clip, _ atBeat: Double) -> Void = { _, _, _ in }
    var onSetClipFades: (_ trackID: UUID, _ clip: Clip, _ fadeIn: Double, _ fadeOut: Double,
                         _ inCurve: FadeCurve, _ outCurve: FadeCurve) -> Void = { _, _, _, _, _, _ in }
    var onSetClipGain: (_ trackID: UUID, _ clip: Clip, _ gainDb: Double) -> Void = { _, _, _ in }
    /// Submits an audio clip's whole gain-envelope point array (m13-e; wired to
    /// `ProjectStore.setClipGainEnvelope`). Empty clears it.
    var onSetClipGainEnvelope: (_ trackID: UUID, _ clip: Clip, _ points: [ClipGainPoint]) -> Void = { _, _, _ in }
    /// The stretch HANDLE (M5 ii-e): alt-drag the right edge of an AUDIO clip to
    /// retarget its timeline length while holding the source window (wired to
    /// `ProjectStore.stretchClip`, NOT trim). MIDI right-edge alt-drag stays trim.
    var onStretchClip: (_ trackID: UUID, _ clip: Clip, _ toLengthBeats: Double) -> Void = { _, _, _ in }
    /// Opens the Quantize panel for a clip (m11-a) — MIDI note quantize (arrange
    /// context menu, Pro; sp-c). UI-only, routes to `openQuantizePanel`.
    var onOpenQuantize: (_ clip: Clip) -> Void = { _ in }
    /// Opens the Quantize panel focused on the extract affordance (both kinds).
    var onExtractGroove: (_ clip: Clip) -> Void = { _ in }
    /// Opens the "Convert to Voice…" sheet for an AUDIO clip (m10-p-5, Pro clip
    /// menu; sp-c). UI-only — routes to `openVoiceConvert`, whose sheet rides
    /// the SAME client/store seams as the wire's `vc.convertVocals`.
    var onConvertToVoice: (_ clip: Clip) -> Void = { _ in }
    /// Crossfades two adjacent/overlapping audio clips (m11-d, Pro clip menu),
    /// wired to `ProjectStore.crossfadeClips`.
    var onCrossfadeClips: (_ trackID: UUID, _ clipID: UUID, _ otherClipID: UUID,
                           _ lengthBeats: Double) -> Void = { _, _, _, _ in }
    /// Engine-reported offline stretch-render state per clip (pull-based, M5 ii-e):
    /// drives the rendering shimmer / error accent on the block. Default: nothing
    /// pending (previews and headless runs read `.idle`).
    var stretchStatus: (_ clip: Clip) -> ClipStretchStatus? = { _ in nil }

    // MARK: Take lanes (M5 iii-c)

    /// Tracks whose take-lanes section is expanded (shared with the sidebar via
    /// AppModel so both columns grow the same rows). Only tracks with take groups
    /// actually draw the section.
    var expandedTakeTrackIDs: Set<UUID> = []
    /// Replaces a group's comp wholesale (wired to `setCompSegments`, coalesced).
    var onSetTakeComp: (_ trackID: UUID, _ groupID: UUID, _ segments: [CompSegment]) -> Void = { _, _, _ in }
    /// Whole-lane take swap (wired to `selectTake`).
    var onSelectTake: (_ trackID: UUID, _ groupID: UUID, _ laneID: UUID) -> Void = { _, _, _ in }
    /// Dissolves a group into ordinary clips (wired to `flattenTakeGroup`).
    var onFlattenTakeGroup: (_ trackID: UUID, _ groupID: UUID) -> Void = { _, _ in }
    /// Deletes a lane (wired to `removeTakeLane`).
    var onRemoveTakeLane: (_ trackID: UUID, _ groupID: UUID, _ laneID: UUID) -> Void = { _, _, _ in }

    // MARK: Loop region (beta m10-g)

    /// Loop transport state, threaded in read-only by value from
    /// `store.transport` so an agent's `transport.setLoop` over the wire updates the
    /// band immediately (the m10-e live-sync rule). A region exists when
    /// `loopEndBeat > loopStartBeat` (the transport's own invariant); a default
    /// 0…0 (previews / untouched headless callers) renders nothing.
    var isLoopEnabled: Bool = false
    var loopStartBeat: Double = 0
    var loopEndBeat: Double = 0
    /// Commits a sketched/resized/moved region (wired to `ProjectStore.setLoop`).
    /// Create passes `enabled: true` (you just drew a loop); resize/move preserve
    /// the current enabled state; the click-toggle flips it keeping the region.
    var onSetLoop: (_ enabled: Bool, _ startBeat: Double, _ endBeat: Double) -> Void = { _, _, _ in }
    /// Seeks the transport to a snapped beat (wired to `ProjectStore.seek`) — a
    /// click on empty ruler, so the ruler is never a dead click surface (the m10-e
    /// piano-roll-strip idiom, one surface over).
    var onSeek: (_ beat: Double) -> Void = { _ in }

    // MARK: Session markers (m11-c)

    /// Session markers, threaded in by value from `store.markers` (already SORTED
    /// by beat) so an agent's `marker.add`/`move` over the wire updates the lane
    /// live (the loop-band live-sync rule). Empty (previews / untouched callers)
    /// renders no flags.
    var markers: [Marker] = []
    /// Adds a marker at a snapped beat (wired to `ProjectStore.addMarker`) — the
    /// marker-lane context menu's "Add Marker Here".
    var onAddMarker: (_ beat: Double) -> Void = { _ in }
    /// Moves a marker to a snapped beat (wired to `ProjectStore.moveMarker`, which
    /// coalesces a live scrub into one undo step).
    var onMoveMarker: (_ markerID: UUID, _ beat: Double) -> Void = { _, _ in }
    /// Commits a marker rename (wired to `ProjectStore.renameMarker`; the store
    /// applies the trim / empty-cancel / unchanged-no-op rules).
    var onRenameMarker: (_ markerID: UUID, _ name: String) -> Void = { _, _ in }
    /// Removes a marker (wired to `ProjectStore.removeMarker`).
    var onRemoveMarker: (_ markerID: UUID) -> Void = { _ in }
    /// Capture-only staging seam (`debug.markerRename`): when non-nil, opens that
    /// marker's inline rename field. nil in normal use (double-click / the context
    /// menu drive `renamingMarkerID` directly).
    var stageRenameMarkerID: UUID? = nil

    // MARK: Pointer affordances (m17-c)

    /// Staged pointer event from `debug.arrangePointer` (nil in normal use).
    /// The view runs it through the SAME hover / click-seek / double-click-split
    /// handlers a real pointer uses — hover isn't injectable on the unbundled
    /// staging binary (the m17-b Accessibility measurement), so the seam stages
    /// and this view mirrors (the `stageRenameMarkerID` precedent).
    var stagePointer: ArrangePointerStage? = nil
    /// Reports the pointer layer's live state (zone + snapped ghost beat) up to
    /// the AppModel so `debug.arrangePointer` echoes ground truth. Real hovers
    /// and staged events feed the same callback.
    var onPointerState: ((_ zone: ArrangePointerZone, _ ghostBeat: Double?) -> Void)? = nil
    /// A refused arrange edit to surface (m17-c): the store's message VERBATIM
    /// as a transient amber bubble on the refused clip's block — or (m23-e) on
    /// the lane an empty-lane create was refused on.
    var splitRefusal: ArrangeSplitRefusal? = nil
    /// m23-e: an empty-lane double-click asks for a new MIDI clip on that lane.
    /// The view resolves the LANE and the SNAPPED beat (the same beat a single
    /// click seeks to) and the meter-aware, gap-clamped length; the parent makes
    /// the one `ProjectStore.addMIDIClip` call and opens the editor on the
    /// result — or surfaces the store's refusal verbatim for an audio/bus lane.
    var onCreateMIDIClip: (_ trackID: UUID, _ atBeat: Double, _ lengthBeats: Double) -> Void = { _, _, _ in }

    // MARK: Empty-lane hint (m23-v)

    /// Reports the empty-lane hints this view is DRAWING, on first render and
    /// whenever they change (`debug.arrangePointer`'s `emptyLaneHints` echo).
    ///
    /// It is a SEPARATE path from `onPointerState` on purpose, and that is the
    /// design decision of the item, not plumbing: the pointer seam fires on hover
    /// and clears on exit, so it reports null in precisely the resting state this
    /// hint exists for. This one is keyed on lane CONTENT.
    ///
    /// THE ECHO-SEAM LAW (m23-e, `DAWProApp.swift:725`): the reported value is
    /// the value `emptyLaneHintLayer` iterates to draw, composed once, and the
    /// reporter is attached to that layer — so a build that removes the layer
    /// from the lane stack stops reporting too, and cannot answer `true` for
    /// pixels it never drew. Recomputing the predicate in `AppModel` for the echo
    /// would have made the whole gate decoration (the m23-m3b measurement: a
    /// mutant that broke a `DAWApp`-only binding left the entire Swift suite
    /// green, because no test target reaches this module).
    var onEmptyLaneHints: (([ArrangeEmptyLaneHint]) -> Void)? = nil

    // MARK: Rubber band (m23-g3)

    /// Staged marquee step from `debug.arrangeMarquee` (nil in normal use). Runs
    /// through the SAME handlers the real `DragGesture` runs — a real mouse drag
    /// is not injectable on the unbundled staging binary (the m17-b
    /// Accessibility measurement), so the seam stages and this view mirrors.
    var stageMarquee: ArrangeMarqueeStage? = nil
    /// Asks the parent to apply a marquee's outcome to the selection. THREE
    /// values, not one: `hits` is what the band touches RIGHT NOW, `base` is the
    /// selection as it stood when the drag began, and `additive` is the chord.
    /// The base is required because a marquee re-decides on every update — a
    /// shrinking band must give clips back, which is impossible if the handler
    /// can only see the selection it has already been growing.
    var onMarqueeSelect: ((_ hits: Set<UUID>, _ base: Set<UUID>, _ additive: Bool) -> Void)? = nil
    /// Reports the band layer's live state UP so `debug.arrangeMarquee` echoes
    /// ground truth, never its own input (the `onDropState` discipline). `band`
    /// is nil exactly when no marquee is in flight — which is the ONLY honest
    /// way to prove "the band is standing mid-drag and gone after".
    var onMarqueeState: ((_ band: CGRect?, _ hits: Set<UUID>) -> Void)? = nil
    /// Reports the RESOLVED lane ladder (tops + the live clip-lane height) UP,
    /// on first render and whenever it changes. Separate from `onMarqueeState`
    /// on purpose: a caller must be able to read the ladder from a BARE seam
    /// call — before any drag exists — or it is back to hardcoding a pitch the
    /// app does not use (see `ArrangeLaneGeometry`).
    var onLaneGeometry: ((ArrangeLaneGeometry) -> Void)? = nil

    // MARK: File import drag-drop (beta m10-k; MIDI m23-k4b)

    /// Imports dropped file URLs — audio AND `.mid` (wired to
    /// `AppModel.importFiles`, which runs the shared `AudioImportPlan` pipeline).
    /// `targetTrackID` is the lane under the pointer (its kind + the file count +
    /// whether the drag carries MIDI decide routing in the plan); `landing` is
    /// the beat ALREADY resolved by the same `ArrangeDropSnap.resolve` call that
    /// drew the drop line (m23-f) — nothing downstream re-snaps it, and the MIDI
    /// import lands on that very value too.
    var onImportFiles: (_ urls: [URL], _ targetTrackID: UUID?, _ landing: ResolvedDropBeat) -> Void = { _, _, _ in }

    /// Staged drop event from `debug.arrangeDrop` (m23-f; nil in normal use).
    /// Runs through the SAME `AudioLaneDropCore` a real Finder drag runs —
    /// `DropInfo` has no public initializer, so the seam drives the core, not a
    /// fake OS event (the `stagePointer` precedent).
    var stageDrop: ArrangeDropStage? = nil
    /// Reports the drop layer's state UP to the AppModel so `debug.arrangeDrop`
    /// echoes ground truth, never the seam's own input. TWO values on purpose:
    /// `live` is the hover `@State` as it stands after the handler ran (i.e.
    /// whether a drop line is actually standing — the report-(2) measurement),
    /// `decided` is what the handler itself resolved (never re-read, the
    /// `onPointerState` discipline). They differ exactly where the interesting
    /// bug is: a drop DECIDES a landing and must leave NO live hover.
    var onDropState: ((_ live: AudioDropHover?, _ decided: AudioDropHover?) -> Void)? = nil
    /// Reports the LIVE drop hover whenever it changes for ANY reason — notably
    /// the ordinary-pointer dismissal, which is not a drag event and so never
    /// reaches `onDropState`. Without this the seam's mirror would keep
    /// answering with a hover the view had already cleared: the stale-echo class
    /// that does not merely fail a gate but poisons every diagnosis made
    /// through it. (It caught exactly that here — the dismissal was working and
    /// the echo was lying about it.)
    var onDropHoverChange: ((AudioDropHover?) -> Void)? = nil

    // MARK: Tempo + meter maps (m12-d)

    /// The project's RESOLVED meter map, threaded by value from `store.transport`
    /// so a wire `tempo.setMap` updates the ruler bar lines/numbers live. Drives
    /// meter-aware bar numbering (correct across a 7/8→4/4 change) and the
    /// meter-aware bar snap. A trivial single-4/4 map reproduces the legacy grid.
    var meterMap: MeterMap = MeterMap(constant: TimeSignature())
    /// The project's RESOLVED tempo map, threaded by value from `store.transport`
    /// so a wire `tempo.setMap` updates the tempo lane + the amber clip hint live.
    var tempoMap: TempoMap = TempoMap(constantBPM: 120)
    /// The tempo lane's headless model (m12-d) — reads the maps and applies every
    /// edit through `ProjectStore.setTempoMap`. Shared with `debug.tempoLane` so a
    /// headless capture drives the SAME instance the live ruler renders.
    var tempoLane: TempoLaneModel
    /// True while the transport is recording — the tempo lane is read-only then
    /// (map edits are refused mid-take; the lane greys its handles to match).
    var isRecordingTransport: Bool = false

    // MARK: - Ruler-block pinning (m13-g)

    /// Which slice this instance renders. `.full` (default) keeps the legacy
    /// single-view composition for previews / headless callers; the live arrange
    /// passes `.ruler` (pinned) and `.lanes` (scrolling).
    var content: ArrangeContent = .full
    /// `.ruler` only: the live horizontal offset to shift the ruler by so it tracks
    /// the `.lanes` instance's horizontal scroll.
    var hScrollOffset: CGFloat = 0
    /// `.lanes` only: reports the live horizontal scroll offset so the pinned ruler
    /// mirrors it (the m10-j shared-scroll discipline, on the horizontal axis).
    var onHScrollChange: ((CGFloat) -> Void)? = nil
    /// `.lanes` only (m17-b): a programmatic horizontal scroll request — the
    /// anchor-preserving offset a zoom computed, or (m23-c2) a follow page turn.
    /// Applied via `ScrollViewReader` against a layout-real 1 pt marker at that
    /// content x (`scrollTo` with a `.leading` anchor lands the viewport edge
    /// exactly on it — the `debug.arrangeScroll` vertical precedent; SwiftUI's
    /// native scroller has no pixel-precise offset API on the macOS 14 floor).
    /// `hScrollApplyNonce` bumps per request so a repeat of the same offset still
    /// applies. Plain SwiftUI throughout — there is no AppKit bridge here.
    var hScrollApplyTarget: CGFloat? = nil
    var hScrollApplyNonce: Int = 0
    /// `.lanes` only (m23-c2): reports the laid-out content width, so follow can
    /// clamp its target to the real timeline instead of forking `totalBeats`.
    var onContentWidthChange: ((CGFloat) -> Void)? = nil

    /// The scroll-anchor marker's identity for `scrollTo` (m17-b).
    private static let hScrollMarkerID = "arrangeHScrollMarker"

    /// Stationary content coordinate space — clip drags measure against this so a
    /// block moving under the cursor never feeds its own translation back.
    static let contentSpace = "arrangeContent"
    /// The `.lanes` horizontal scroll coordinate space — the offset the ruler reads.
    static let hScrollSpace = "arrangeHScroll"

    /// The ruler's vertical inset above the lane content. In `.lanes` the ruler is
    /// pinned elsewhere so lanes start at y = 0; `.full` / `.ruler` keep the ruler
    /// strip (`rulerHeight`) so bar lines and the ruler baseline seat correctly.
    private var rulerInset: CGFloat { content == .lanes ? 0 : Self.rulerHeight }

    /// Shared clip hit/geometry model at the timeline scale. Reads the live
    /// `rowHeight` so trim/fade/gain hit-testing tracks the adjustable lane height,
    /// and the live `pixelsPerBeat` so every clip gesture derives beats from x at
    /// the current zoom (m17-b).
    private var clipGeometry: ClipEditGeometry {
        ClipEditGeometry(pixelsPerBeat: pixelsPerBeat, laneHeight: rowHeight)
    }

    // Row metrics tuned to line up with the sidebar track rows (TrackListView:
    // 42 pt header, 6 pt gaps). The clip-lane height is the DEFAULT for the
    // adjustable `rowHeight` input (beta m10-d) — the sidebar rows read the same
    // store value, so both columns scale in lockstep.
    /// The historical fixed scale — the default for the zoomable `pixelsPerBeat`
    /// input below (m17-b) and the ⌘0 reset target (`ArrangeZoom` owns the math).
    static let defaultPixelsPerBeat: CGFloat = ArrangeZoom.defaultPixelsPerBeat
    /// Ruler height (m11-c grew it 42 → 56 for the marker lane; m12-d grows it
    /// 56 → 80 to seat the TEMPO LANE below the marker lane — each ruler surface
    /// gets its own strip, so no hit zone is overloaded). Top→bottom the 80 pt
    /// ruler stacks: loop band `y ∈ [2, 14]`, marker lane `y ∈ [15, 33]`, tempo
    /// lane `y ∈ [35, 57]` (meter flags in its top row, bpm in its bottom row),
    /// bar numbers `y ≈ 62…71`, baseline at `y = 79`.
    static let rulerHeight: CGFloat = 80
    static let laneHeight: CGFloat = 34
    static let laneSpacing: CGFloat = 6
    /// The empty-lane hint (m23-v): 11 pt SF Pro, inset from the content origin
    /// by a little more than the playhead's own half-width so the two never touch
    /// at beat 0 with the transport parked at the start (the first thing a new
    /// user sees). It rides the SMALLEST row height the app can show — S rows are
    /// 24 pt — so 11 pt is the largest size that still leaves clear air above and
    /// below the glyphs at every step of the S/M/L ladder.
    static let emptyLaneHintFontSize: CGFloat = 11
    static let emptyLaneHintInsetX: CGFloat = 10
    /// The loop region band (beta m10-g) draws as a distinct strip in the TOP of
    /// the ruler — `y ∈ [loopBandTop, loopBandTop + loopBandHeight]` in content
    /// space — so it sits clear of the bar numbers and the marker lane and reads as
    /// a dedicated loop track. The loop gestures own the ruler EXCEPT the marker-
    /// lane strip (which the marker lane, layered on top, carves out — m11-c).
    static let loopBandTop: CGFloat = 2
    static let loopBandHeight: CGFloat = 12
    /// The session-marker lane (m11-c) draws its flags in a distinct strip BELOW
    /// the loop band — `y ∈ [markerLaneTop, markerLaneTop + markerLaneHeight]` —
    /// clear of both the loop band above and the bar numbers below. This strip is
    /// the marker gesture surface (layered over the loop ruler), so a press here
    /// grabs/adds a marker instead of the loop.
    static let markerLaneTop: CGFloat = 15
    static let markerLaneHeight: CGFloat = 18
    /// The tempo lane (m12-d) draws its segment bars + boundary handles + meter
    /// flags in a distinct strip BELOW the marker lane — `y ∈ [tempoLaneTop,
    /// tempoLaneTop + tempoLaneHeight]` — clear of the marker flags above and the
    /// bar numbers below. This strip is the tempo gesture surface (layered over the
    /// loop ruler), so a press here edits the tempo map instead of the loop.
    static let tempoLaneTop: CGFloat = 35
    static let tempoLaneHeight: CGFloat = 22
    /// Pointer movement (points) that separates a ruler CLICK (toggle/seek) from a
    /// DRAG (sketch/resize/move) — below it the press stays a click. Shared by the
    /// loop ruler and the marker-flag drag (m11-c).
    static let loopClickSlop: CGFloat = 4
    /// The automation editor row height an expanded track adds — shared with the
    /// sidebar's control panel so both columns grow by the same amount.
    static let automationLaneHeight: CGFloat = 64
    /// One take-lane sub-row's height (M5 iii-c) — shared with the sidebar's take
    /// controls and the headless `TakeLaneGeometry`.
    static let takeLaneRowHeight: CGFloat = 26
    /// A take group's header strip height inside the section.
    static let takeGroupHeaderHeight: CGFloat = 18

    /// Full height a track's expanded takes section occupies: one header + a
    /// sub-row per lane, summed across the track's groups. Shared verbatim by the
    /// sidebar so the two columns grow by the same amount.
    static func takesSectionHeight(_ track: Track) -> CGFloat {
        track.takeGroups.reduce(0) {
            $0 + takeGroupHeaderHeight + CGFloat($1.lanes.count) * takeLaneRowHeight
        }
    }

    private func isExpanded(_ track: Track) -> Bool { expandedTrackIDs.contains(track.id) }

    /// A track shows its takes section only when expanded AND it actually has
    /// groups (an empty group list draws nothing, like automation with no lanes).
    private func isTakesExpanded(_ track: Track) -> Bool {
        expandedTakeTrackIDs.contains(track.id) && !track.takeGroups.isEmpty
    }

    private func takesHeight(_ track: Track) -> CGFloat {
        isTakesExpanded(track) ? Self.takesSectionHeight(track) : 0
    }

    private var takeGeometry: TakeLaneGeometry {
        TakeLaneGeometry(pixelsPerBeat: pixelsPerBeat, rowHeight: Self.takeLaneRowHeight)
    }

    /// The automation lane a track is editing (explicit selection or its first).
    private func selectedLane(for track: Track) -> AutomationLane? {
        AutomationLaneSelection.selectedLane(in: track, selection: selectedLaneByTrack[track.id])
    }

    private var totalBeats: Int {
        let lastClipEnd = tracks
            .flatMap(\.clips)
            .map { $0.startBeat + $0.lengthBeats }
            .max() ?? 0
        // Display-only padding heuristic (m13-h): the base meter (beat 0) is a fine
        // divisor for "how many empty bars to show" — this is not a snap path.
        let basePerBar = meterMap.beatsPerBar(atBeat: 0)
        let bars = Int((lastClipEnd / Double(basePerBar)).rounded(.up)) + 2
        // Zoom padding (m17-b), in whole empty bars:
        //  (a) zoomed far out, a short session would otherwise shrink to a thin
        //      strip — pad to fill the viewport width;
        //  (b) an anchor-preserving zoom-in needs the WINDOW at its scroll
        //      target to exist — pad to `target + viewport`, else the scroller
        //      clamps the jump to the old content edge and the anchor drifts.
        // Both the `.ruler` and `.lanes` instances receive the SAME
        // `availableWidth` + `hScrollApplyTarget` (one call site builds both),
        // so their content widths stay identical (alignment law).
        var minBeats = 32
        if availableWidth > 0, pixelsPerBeat > 0 {
            let neededWidth = availableWidth + max(0, hScrollApplyTarget ?? 0)
            let neededBeats = Int((neededWidth / pixelsPerBeat).rounded(.up))
            let neededBars = Int((Double(neededBeats) / Double(basePerBar)).rounded(.up))
            minBeats = max(minBeats, neededBars * basePerBar)
        }
        return max(bars * basePerBar, minBeats)
    }

    private var contentWidth: CGFloat { CGFloat(totalBeats) * pixelsPerBeat }

    /// Extra height a track contributes below its clip lane: its takes section
    /// (directly under the clips) then its automation row (the same order the
    /// sidebar stacks its control panels, so both columns stay aligned).
    private func extraHeight(_ track: Track) -> CGFloat {
        takesHeight(track) + (isExpanded(track) ? Self.automationLaneHeight : 0)
    }

    private var contentHeight: CGFloat {
        // The pinned ruler block is exactly the ruler strip — no lanes.
        if content == .ruler { return Self.rulerHeight }
        var y = rulerInset
        for track in tracks {
            y += rowHeight + extraHeight(track) + Self.laneSpacing
        }
        return y
    }

    /// Top y of track `index`'s clip lane, accounting for expanded tracks above.
    private func laneTop(_ index: Int) -> CGFloat {
        var y = rulerInset
        for i in 0..<index {
            y += rowHeight + extraHeight(tracks[i]) + Self.laneSpacing
        }
        return y
    }

    /// Top y of track `index`'s takes section (directly below its clips).
    private func takesTop(_ index: Int) -> CGFloat {
        laneTop(index) + rowHeight
    }

    /// Top y of track `index`'s automation editor row (below clips + takes).
    private func automationTop(_ index: Int) -> CGFloat {
        laneTop(index) + rowHeight + takesHeight(tracks[index])
    }

    /// Green audio / cyan MIDI, violet whenever the clip is AI-touched
    /// (docs/DESIGN-LANGUAGE.md: violet = AI content, always).
    private func tint(_ clip: Clip) -> Color {
        if clip.isAIGenerated { return DAWTheme.ai }
        return clip.isMIDI ? DAWTheme.playback : DAWTheme.signal
    }

    // MARK: - Density (Simple locks the grid to Bar; Pro is the full edit layer)

    /// Stable density key for the whole arrange workspace — one mode for the
    /// timeline + clip chrome + snap picker (docs/DESIGN-LANGUAGE.md "Panels").
    static let panelID = "arrange"

    /// True when the arrange workspace is in Pro (the full clip-edit layer). Simple
    /// hides the trim/fade/split/gain/stretch chrome + their gestures and locks snap.
    private var isPro: Bool { densityStore.density(forPanel: Self.panelID) == .pro }

    /// The snap the CLIP lane actually uses: the picked resolution in Pro, locked
    /// to Bar in Simple (mirroring the piano roll locking Simple to Beat). The
    /// picker value is never mutated, so flipping back to Pro restores it. Take
    /// lanes deliberately keep the raw picked `snap` (density leaves them untouched).
    private var effectiveSnap: ClipSnap {
        ClipSnap.effective(density: densityStore.density(forPanel: Self.panelID), picked: snap)
    }

    /// The loop-ruler drag in flight (beta m10-g): nil at rest / during a click,
    /// set once a press crosses the click slop. Drives the live band preview.
    @State private var loopDrag: LoopDragState?

    /// A programmatic scroll request not yet confirmed against laid-out geometry
    /// (m17-b): set when `hScrollApplyNonce` bumps, cleared when the width report
    /// confirms the layout and the final `scrollTo` is issued.
    @State private var hScrollApplyPending = false
    /// The last laid-out `.lanes` content width (reported by the content
    /// GeometryReader's `.onChange`, same delivery as the h-offset mirror) —
    /// the signal that a pending programmatic scroll can land exactly, and the
    /// ceiling follow clamps its page targets to (m23-c2).
    @State private var laidOutContentWidth: CGFloat = 0

    /// The marker-flag drag in flight (m11-c): nil at rest / during a click, set
    /// once a press on a flag crosses the click slop. Drives the live flag preview
    /// and the coalesced move-scrub.
    @State private var markerDrag: MarkerDragState?
    /// Which marker (if any) is being renamed in place; its flag shows a field.
    @State private var renamingMarkerID: UUID?
    /// The last content-space beat the pointer hovered in the marker lane — the
    /// beat "Add Marker Here" uses (the context menu carries no location itself).
    @State private var markerAddHoverBeat: Double = 0

    /// Live audio-file drop hover (beta m10-k): where a Finder drop would land and
    /// which lane it targets, so the arrange paints the cyan target affordance. nil
    /// when nothing is hovering a valid audio drop.
    @State private var dropHover: AudioDropHover?
    /// The drag-session phase behind that hover (m23-f). A `DropDelegate` hover
    /// is armed and cleared only by drag callbacks, so it needs an owner that
    /// knows whether a drag is still in flight — without it, a post-drop
    /// `update` re-arms an overlay nothing will ever clear again.
    @State private var dropSession = ArrangeDropSession()

    /// The snapped beat the lanes hover ghost line previews (m17-c) — nil unless
    /// the pointer is over EMPTY timeline space (never over a clip, the extras
    /// editors, or the playhead grab strip).
    @State private var ghostBeat: Double?
    /// True once a playhead grab drag crossed the scrub slop: holds the closed
    /// hand for the whole drag and makes a movement-free press a no-op (grabbing
    /// the playhead without moving must not jump it to a snapped beat).
    @State private var playheadScrubbing = false

    // MARK: Rubber band state (m23-g3)

    /// The marquee in flight (nil at rest). Holds the band ORIGIN and the
    /// selection as it stood at press, so every update re-decides from the same
    /// base instead of accumulating.
    @State private var marqueeSession: MarqueeSession?
    /// The band the view DRAWS — the single source for the visual and for the
    /// `onMarqueeState` report, so the seam can never claim a band the user
    /// cannot see.
    @State private var marqueeBand: CGRect?
    /// When a marquee last ENDED. Consumed by the single-tap handler to swallow
    /// the tap SwiftUI may synthesize from the same mouse-up — see
    /// `consumeMarqueeClickSuppression`.
    @State private var marqueeEndedAt: Date?

    /// A live marquee's immutable inputs.
    private struct MarqueeSession: Equatable {
        /// Content-space point the press landed on (the band's fixed corner).
        var origin: CGPoint
        /// The selection at press — what a shift-marquee unions ONTO, and what a
        /// shrinking band gives back to.
        var base: Set<UUID>
        /// shift/⌘ held at press: union rather than replace.
        var additive: Bool
    }

    /// How long after a marquee release a single tap is treated as that
    /// release's echo rather than a fresh click. Chosen well under a
    /// double-click interval, and the suppression is CONSUMED by the first tap
    /// either way, so a stale flag can never eat a later deliberate click.
    private static let marqueeClickSuppressWindow: TimeInterval = 0.25

    var body: some View {
        Group {
            switch content {
            case .full:  fullBody
            case .lanes: lanesBody
            case .ruler: rulerBody
            }
        }
        // Capture staging (m11-c): mirror the debug-driven rename target into the
        // live @State the flag reads. Runs on set and on first appearance so a
        // staged value present before the view mounts still opens the field.
        .onChange(of: stageRenameMarkerID) { _, id in renamingMarkerID = id }
        .onAppear { if let id = stageRenameMarkerID { renamingMarkerID = id } }
        // Pointer staging (m17-c): run a debug-staged pointer event through the
        // SAME handlers a real hover/click uses. Only the lane-bearing instance
        // reacts — the pinned `.ruler` block has no pointer layer.
        .onChange(of: stagePointer) { _, stage in applyPointerStage(stage) }
        .onAppear { applyPointerStage(stagePointer) }
        // Drop staging (m23-f): same discipline as the pointer seam — the staged
        // event runs through the SAME AudioLaneDropCore a real Finder drag runs.
        .onChange(of: stageDrop) { _, stage in applyDropStage(stage) }
        .onAppear { applyDropStage(stageDrop) }
        // Keep the seam's mirror honest for hover changes that did NOT come from
        // a staged drag phase (the pointer dismissal). Belt-and-braces with the
        // synchronous report in `handlePointerHover`.
        .onChange(of: dropHover) { _, hover in onDropHoverChange?(hover) }
        // Selection render report (m23-g1). `.onChange` runs AFTER the body has
        // been re-evaluated with the new selection, which is exactly the claim
        // the seam needs before it answers or a gate captures. The `.ruler`
        // instance is excluded so exactly one reporter exists.
        .onChange(of: selection) { _, _ in
            if content != .ruler { onSelectionRendered?() }
        }
        // Clip-layout render report (m23-g2), the selection report's twin for a
        // GROUP MOVE — which changes no selection at all, so the report above
        // would never fire for it and a seam waiting on it would time out.
        .onChange(of: clipLayoutSignature) { _, _ in
            if content != .ruler { onClipLayoutRendered?() }
        }
        // Marquee staging (m23-g3): same discipline as the pointer and drop
        // seams — the staged step runs through the SAME handlers the real
        // `DragGesture` runs, so the seam cannot drift from the gesture.
        .onChange(of: stageMarquee) { _, stage in applyMarqueeStage(stage) }
        .onAppear { applyMarqueeStage(stageMarquee) }
        // The RESOLVED lane ladder, reported on first render and on every change
        // (a track expanding its automation row, a row-height change, a track
        // added/removed). `initial: true` is what makes a BARE
        // `debug.arrangeMarquee {}` able to answer before any drag exists.
        .onChange(of: laneGeometry, initial: true) { _, geometry in
            if content != .ruler { onLaneGeometry?(geometry) }
        }
    }

    /// The lanes' resolved ladder, built from `laneTop` — the ONE producer of
    /// arrange row positions. Nothing here multiplies out a pitch; that is the
    /// whole point (see `ArrangeMarquee`).
    private var laneGeometry: ArrangeLaneGeometry {
        ArrangeLaneGeometry(laneTops: tracks.indices.map { laneTop($0) }, rowHeight: rowHeight)
    }

    /// A compact hash of every clip's identity + horizontal geometry — the
    /// change signal behind `onClipLayoutRendered`.
    ///
    /// Deliberately NOT `.onChange(of: tracks)`: `Track` equality walks notes,
    /// controller lanes, automation and take groups, i.e. a deep compare of the
    /// whole arrangement on every body pass. This walks the clip list only —
    /// which the body already walks to lay out the blocks — so the report costs
    /// asymptotically nothing next to the render it is reporting on.
    private var clipLayoutSignature: Int {
        var hasher = Hasher()
        for track in tracks {
            for clip in track.clips {
                hasher.combine(clip.id)
                hasher.combine(clip.startBeat)
                hasher.combine(clip.lengthBeats)
            }
        }
        return hasher.finalize()
    }

    /// The `.lanes` viewport-filling height: fill the shared-scroll viewport when
    /// the lanes are shorter than it (so the glass column stays flush with the
    /// sidebar), else the natural content height so the outer vertical scroll owns
    /// the overflow (m10-j).
    private var laneStackHeight: CGFloat { max(contentHeight, availableHeight) }

    // MARK: - Full body (legacy: ruler + lanes in one horizontal scroll)

    @ViewBuilder
    private var fullBody: some View {
        let laneHeight = laneStackHeight
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                grid
                pointerHoverSurface
                emptyLaneHintLayer
                loopBand
                clipBlocks
                crossfadeSeams
                takeLanes
                automationLanes
                dropAffordance
                marqueeBandView
                ghostLine
                playhead
                playheadGrabStrips
                laneRefusalBubble
                loopRuler
                markerLane
                tempoLaneView
            }
            .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
            .coordinateSpace(name: Self.contentSpace)
            .onDrop(of: [.fileURL], delegate: laneDropDelegate)
        }
        .frame(height: laneHeight, alignment: .topLeading)
        .glassPanel()
    }

    // MARK: - Lanes body (m13-g: scrolling lane content, reports its h-offset)

    @ViewBuilder
    private var lanesBody: some View {
        let laneHeight = laneStackHeight
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    grid
                    pointerHoverSurface
                    // m23-v: lane CONTENT (like the clip note map), so it draws
                    // under everything interactive and under the ghost line /
                    // playhead / refusal bubble, which must read over it.
                    emptyLaneHintLayer
                    clipBlocks
                    crossfadeSeams
                    takeLanes
                    automationLanes
                    dropAffordance
                    marqueeBandView
                    ghostLine
                    playhead
                    playheadGrabStrips
                    laneRefusalBubble
                    hScrollMarker
                }
                .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
                .coordinateSpace(name: Self.contentSpace)
                // Pinch zoom (m17-b): two-finger magnification over the lanes area,
                // anchored at the pointer. Simultaneous so clip drags / taps are
                // untouched (a pinch is a distinct two-finger gesture).
                .simultaneousGesture(pinchZoomGesture)
                // Report the live horizontal scroll offset (content minX in the scroll
                // space, negated) so the pinned ruler mirrors it — the m10-j shared-
                // scroll discipline on the horizontal axis (no second vertical scroll,
                // so the columns can't desync; only the ruler tracks this offset).
                // Report the live scroll offset + laid-out width via `.onChange`
                // INSIDE the GeometryReader (m17-b, measured): on this macOS the
                // native ScrollView never re-delivers `.preference()` changes
                // emitted from its content (only the initial default arrived at
                // any listener, content-side included), while the GeometryReader
                // itself demonstrably re-evaluates with fresh geometry on every
                // scroll/resize — so the reporting rides view-update machinery,
                // not preference machinery (the header note above the view
                // records the measurement; the old PreferenceKeys are gone).
                .background(GeometryReader { geo in
                    let minX = geo.frame(in: .named(Self.hScrollSpace)).minX
                    let width = geo.size.width
                    Color.clear
                        .onChange(of: minX, initial: true) { _, v in
                            onHScrollChange?(-v)
                        }
                        .onChange(of: width, initial: true) { _, v in
                            laidOutContentWidth = v
                            onContentWidthChange?(v)
                        }
                })
                .onDrop(of: [.fileURL], delegate: laneDropDelegate)
            }
            .coordinateSpace(name: Self.hScrollSpace)
            // A programmatic horizontal scroll (m17-b zoom anchor / m23-c2 follow
            // page turn): jump the viewport's leading edge onto the layout-real
            // marker. `scrollTo` consults LIVE layout, so the request lands in two
            // stages: a best-effort jump now (exact whenever the content is
            // already laid out at this width), and the confirming jump once
            // `laidOutContentWidth` reports the new width (without it, a zoom-in
            // clamps against the OLD, shorter content and lands short). Never
            // animated — neither a zoom nor a page turn may glide.
            .onChange(of: hScrollApplyNonce) { _, _ in
                guard hScrollApplyTarget != nil else { return }
                hScrollApplyPending = true
                proxy.scrollTo(Self.hScrollMarkerID, anchor: .leading)
                confirmHScrollApply(proxy)
            }
            .onChange(of: laidOutContentWidth) { _, _ in
                confirmHScrollApply(proxy)
            }
        }
        .frame(height: laneHeight, alignment: .topLeading)
    }

    /// Issues the CONFIRMING scroll once the content's laid-out width matches the
    /// width this view computed — from then on `scrollTo` resolves the marker
    /// against fresh geometry, so the landing is exact.
    ///
    /// The width guard exists for ZOOM, which changes content width; a FOLLOW page
    /// turn does not (its target is clamped to `contentWidth − viewport`, so the
    /// `totalBeats` padding is a no-op), so for follow the guard is already true
    /// and the confirm fires immediately. That is deliberate, not wasted: the
    /// deferred re-issue is what makes the landing DURABLE.
    ///
    /// The confirm lands TWICE (m17-b, measured): once right here — inside the
    /// layout-driven `onChange` — so the very next frame presents at the target
    /// (no one-frame blip), and once more on a fresh main-actor turn. A
    /// `scrollTo` issued from within a layout callback moves the real layout
    /// (geometry reports the target and holds it) but does NOT durably update
    /// the ScrollView's internal position state — any later forced re-render
    /// (window snapshot, resize — `debug.captureUI`'s `cacheDisplay` is exactly
    /// such a re-render) re-resolved from the stale internal value and visibly
    /// jumped the viewport. The deferred re-issue runs outside the layout
    /// transaction and makes the landing stick.
    private func confirmHScrollApply(_ proxy: ScrollViewProxy) {
        guard hScrollApplyPending, hScrollApplyTarget != nil,
              abs(laidOutContentWidth - contentWidth) < 0.5 else { return }
        hScrollApplyPending = false
        proxy.scrollTo(Self.hScrollMarkerID, anchor: .leading)
        Task { @MainActor in
            proxy.scrollTo(Self.hScrollMarkerID, anchor: .leading)
        }
    }

    /// The programmatic scroll anchor (m17-b): a 1 pt, layout-real, hit-test-inert
    /// marker whose LEADING edge sits exactly at the requested offset —
    /// `scrollTo(..., anchor: .leading)` then lands the viewport edge on it
    /// precisely. Built with real frames (never `.offset`) so `scrollTo` reads a
    /// true layout position.
    private var hScrollMarker: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, hScrollApplyTarget ?? 0), height: 1)
            Color.clear
                .frame(width: 1, height: 1)
                .id(Self.hScrollMarkerID)
        }
        .allowsHitTesting(false)
    }

    /// The pinch-zoom gesture (m17-b): reports the pointer's content-space x at
    /// gesture start + the cumulative magnification; the AppModel anchors the
    /// zoom there (`ArrangeZoom.PinchState`) so the beat under the pointer holds
    /// its screen position through the pinch.
    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                onPinchZoomChanged?(value.startLocation.x, value.magnification)
            }
            .onEnded { _ in onPinchZoomEnded?() }
    }

    // MARK: - Ruler body (m13-g: pinned block, horizontally offset to track lanes)

    @ViewBuilder
    private var rulerBody: some View {
        ZStack(alignment: .topLeading) {
            grid
            loopBand
            playhead
            loopRuler
            markerLane
            tempoLaneView
        }
        .frame(width: contentWidth, height: Self.rulerHeight, alignment: .topLeading)
        .coordinateSpace(name: Self.contentSpace)
        // Shift the ruler left by the lanes' scroll offset so bar numbers / loop /
        // marker / tempo stay under the lanes below; clip to the visible viewport.
        .offset(x: -hScrollOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rulerHeight)
        .clipped()
        .contentShape(Rectangle())
    }

    /// The Finder audio-drop delegate — maps the live drop location → target lane +
    /// snapped beat and routes loaded URLs through the shared plan pipeline (m10-k).
    private var laneDropDelegate: AudioLaneDropDelegate {
        AudioLaneDropDelegate(core: laneDropCore)
    }

    /// The `DropInfo`-free drop core (m23-f) — the ONE object both the real
    /// `DropDelegate` adapter and the `debug.arrangeDrop` staging seam drive.
    private var laneDropCore: AudioLaneDropCore {
        AudioLaneDropCore(
            hover: $dropHover,
            session: $dropSession,
            resolve: { point, contents in resolveDropHover(at: point, contents: contents) },
            onImport: onImportFiles)
    }

    /// Runs a debug-staged drop event through the live drop core. `.ruler`
    /// instances carry no drop surface, so they ignore the stage (exactly one
    /// instance reacts per staging) — the `applyPointerStage` rule.
    private func applyDropStage(_ stage: ArrangeDropStage?) {
        guard let stage, content != .ruler else { return }
        let core = laneDropCore
        let point = CGPoint(x: stage.x, y: stage.y)
        let contents = stage.contents
        let decided: AudioDropHover?
        switch stage.action {
        case .enter:  decided = core.enter(at: point, contents: contents)
        case .update: decided = core.update(at: point, contents: contents)
        case .exit:   decided = core.exit()
        case .drop:   decided = core.drop(at: point, urls: stage.urls)
        }
        // `dropHover` is re-read deliberately here: the whole of report (2) is
        // "is a drop line left standing", and only the live state answers that.
        onDropState?(dropHover, decided)
    }

    // MARK: - Grid + ruler (Canvas — no per-frame allocation beyond Paths)

    /// One integer beat's precomputed grid geometry — the meter-aware bar/beat
    /// classification and (at bar starts) the 1-based bar-number label. Built once
    /// per redraw on the main actor so the `@Sendable` grid closure captures only
    /// these plain values, never `self` or `meterMap` (CANVAS CONTRACT, m16-a).
    private struct GridBeatCell {
        var x: CGFloat
        var isBar: Bool
        var barLabel: String?
    }

    private var grid: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let content = content
        let rowHeight = rowHeight
        let rulerHeight = Self.rulerHeight
        // Lane-top offsets (one per track, in order) precomputed off the closure.
        let laneTops: [CGFloat] = tracks.indices.map { laneTop($0) }
        // Grid/label density adapts to the zoom (m17-b, `ArrangeZoom`): per-beat
        // hairlines drop out below the legibility spacing, and bar NUMBERS thin to
        // every 2nd/4th/8th… bar zoomed out (the base meter sizes the stride — a
        // display heuristic like `totalBeats`, not a snap path). Same drawing
        // logic, density-gated — never forked.
        let showBeatLines = ArrangeZoom.showsBeatLines(pixelsPerBeat: pixelsPerBeat)
        let labelStride = ArrangeZoom.barLabelStride(
            pixelsPerBeat: pixelsPerBeat, beatsPerBar: meterMap.beatsPerBar(atBeat: 0))
        // Per-beat classification — the SAME meter math as the legacy in-closure loop,
        // run once here so `meterMap` never crosses into the renderer.
        let beatCells: [GridBeatCell] = (0...totalBeats).map { beat in
            let position = meterMap.barBeat(atBeat: Double(beat))
            let isBar = position.beatInBar < 0.001
            let labeled = isBar && position.bar % labelStride == 0
            return GridBeatCell(
                x: CGFloat(beat) * pixelsPerBeat,
                isBar: isBar,
                barLabel: labeled ? "\(position.bar + 1)" : nil)
        }
        return Canvas { @Sendable context, size in
            // Lane backgrounds — not drawn in the pinned ruler block (m13-g).
            if content != .ruler {
                for top in laneTops {
                    let rect = CGRect(x: 0, y: top, width: size.width, height: rowHeight)
                    context.fill(Path(rect), with: .color(DAWTheme.panelRaised.opacity(0.4)))
                }
            }

            // Vertical beat/bar lines — meter-aware (m12-d): a beat is a BAR line
            // when it starts a bar in the accumulated meter (beatInBar == 0), so a
            // 7/8→4/4 change re-spaces the emphasized lines correctly instead of the
            // legacy fixed `beat % beatsPerBar`. The lines span the drawn height —
            // the ruler strip in the pinned block, the lane stack in the body — so
            // the bar lines in both align at the same x (m13-g).
            var beatLines = Path()
            var barLines = Path()
            for cell in beatCells {
                let line = CGRect(x: cell.x, y: 0, width: 1, height: size.height)
                if cell.isBar {
                    barLines.addRect(line)
                } else if showBeatLines {
                    // Zoomed out (m17-b) the per-beat hairlines drop; bars stay.
                    beatLines.addRect(line)
                }
            }
            context.fill(beatLines, with: .color(DAWTheme.hairline))
            context.fill(barLines, with: .color(DAWTheme.gridEmphasis))

            // Ruler baseline + bar numbers (SF Mono digital readout), meter-aware:
            // each barline draws its 1-based bar index straight from the meter map,
            // so numbering stays sequential and correct across a meter change. Not
            // drawn in the lanes body (the ruler is pinned separately, m13-g).
            if content != .lanes {
                context.fill(
                    Path(CGRect(x: 0, y: rulerHeight - 1, width: size.width, height: 1)),
                    with: .color(DAWTheme.hairline)
                )
                for cell in beatCells {
                    guard let barLabel = cell.barLabel else { continue }
                    let text = Text(barLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(DAWTheme.textDim)
                    context.draw(
                        text,
                        // Below the marker + tempo lanes (m12-d): the bar numbers sit
                        // in the ruler's bottom strip, clear of the flags and handles.
                        at: CGPoint(x: cell.x + 4, y: rulerHeight - 18),
                        anchor: .topLeading
                    )
                }
            }
        }
        .frame(width: contentWidth, height: contentHeight)
    }

    // MARK: - Clip blocks (overlaid views for hit-testing + labels)

    private var clipBlocks: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            ForEach(track.clips) { clip in
                let width = max(3, CGFloat(clip.lengthBeats) * pixelsPerBeat)
                let takeGroup = TakeLaneSelection.group(forMember: clip, in: track)
                ClipBlock(
                    clip: clip,
                    trackID: track.id,
                    tint: tint(clip),
                    isSelected: selection.contains(clip.id),
                    isFocused: selection.isFocus(clip.id),
                    arrangeSelectionCount: selection.count,
                    width: width,
                    height: rowHeight,
                    laneOriginY: laneTop(index),
                    geometry: clipGeometry,
                    snap: effectiveSnap,
                    pro: isPro,
                    meterMap: meterMap,
                    secondsPerBeat: secondsPerBeat,
                    playheadBeat: positionBeats,
                    crossesTempoBoundary: TempoLaneHint.audioClipCrossesBoundary(
                        startBeat: clip.startBeat, lengthBeats: clip.lengthBeats,
                        isMIDI: clip.isMIDI, tempoMap: tempoMap),
                    waveformPeaks: clip.audioFileURL.flatMap { waveformStore.peaks(for: $0) },
                    renderVisual: ClipStretch.renderVisual(for: stretchStatus(clip)),
                    onSelect: { mods in onSelectClip(clip, mods) },
                    onMove: { onMoveClip(track.id, clip, $0, $1) },
                    onTrim: { onTrimClip(track.id, clip, $0, $1) },
                    onFitToContent: { onFitClipToContent(track.id, clip) },
                    onDelete: { onDeleteClip(clip, $0) },
                    onSplit: { onSplitClip(track.id, clip, $0) },
                    onSetFades: { onSetClipFades(track.id, clip, $0, $1, $2, $3) },
                    onSetGain: { onSetClipGain(track.id, clip, $0) },
                    onSetGainEnvelope: { onSetClipGainEnvelope(track.id, clip, $0) },
                    onStretch: { onStretchClip(track.id, clip, $0) },
                    takeBadge: takeGroup.map { TakeLaneSelection.badge(for: $0) },
                    spliceAtStart: takeGroup != nil
                        && TakeLaneSelection.hasLeadingSplice(clip, among: track.clips),
                    takeMenuLanes: (takeGroup?.lanes ?? []).map { ClipBlock.TakeMenuLane(id: $0.id, name: $0.name) },
                    onSelectTakeLane: { laneID in
                        if let g = takeGroup { onSelectTake(track.id, g.id, laneID) }
                    },
                    onFlattenTakeGroup: {
                        if let g = takeGroup { onFlattenTakeGroup(track.id, g.id) }
                    },
                    onOpenQuantize: { onOpenQuantize(clip) },
                    onExtractGroove: { onExtractGroove(clip) },
                    onConvertToVoice: { onConvertToVoice(clip) },
                    crossfadeNextClipID: isPro ? crossfadeNeighbor(for: clip, in: track) : nil,
                    onCrossfadeWithNext: { length in
                        if let other = crossfadeNeighbor(for: clip, in: track) {
                            onCrossfadeClips(track.id, clip.id, other, length)
                        }
                    },
                    refusalMessage: splitRefusal.flatMap {
                        $0.clipID == clip.id ? $0.message : nil
                    }
                )
                .offset(x: CGFloat(clip.startBeat) * pixelsPerBeat, y: laneTop(index))
                // One card summarizes the clip's edit affordances — the honest scope
                // for Canvas/gesture chrome (fade grips, trim edges, ⌥-stretch are
                // gesture-internal, not tag-able views). Per-instance frames anchor it
                // on whichever clip is hovered (ex-b).
                .explainable(.clipBlock)
            }
        }
    }

    // MARK: - Crossfade seams (m11-d)

    /// A small crossfade "bowtie" marker over each overlapping ordinary
    /// audio-clip pair — the visible cue that a sanctioned crossfade sits there
    /// (the clips' own fade wedges shade the overlap; this X anchors the Explain
    /// card and reads the join at a glance). Neutral green (audio), never violet.
    /// Only real overlaps draw one; adjacent-but-not-overlapping clips don't.
    private var crossfadeSeams: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            ForEach(crossfadeSeamMarks(in: track)) { seam in
                CrossfadeSeamBadge()
                    .frame(width: 15, height: 15)
                    .position(x: CGFloat(seam.centerBeat) * pixelsPerBeat,
                              y: laneTop(index) + 9)
                    .explainable(.crossfade)
            }
        }
    }

    /// One crossfade marker: a stable id (the two clip ids) and the beat centre
    /// of the overlap it straddles.
    private struct CrossfadeSeamMark: Identifiable { let id: String; let centerBeat: Double }

    /// The overlapping ordinary audio-clip pairs on `track` (sorted by start),
    /// each yielding one marker centred on the overlap. Comp members and MIDI
    /// clips are excluded — only sanctioned audio crossfades draw a badge.
    private func crossfadeSeamMarks(in track: Track) -> [CrossfadeSeamMark] {
        let audio = track.clips
            .filter { !$0.isMIDI && $0.takeGroupID == nil }
            .sorted { $0.startBeat < $1.startBeat }
        let eps = 1e-6
        var marks: [CrossfadeSeamMark] = []
        for i in stride(from: 0, to: max(0, audio.count - 1), by: 1) {
            let a = audio[i], b = audio[i + 1]
            let aEnd = a.startBeat + a.lengthBeats
            if b.startBeat < aEnd - eps {   // a real overlap (not merely adjacent)
                marks.append(CrossfadeSeamMark(
                    id: "\(a.id.uuidString)|\(b.id.uuidString)",
                    centerBeat: (b.startBeat + aEnd) / 2))
            }
        }
        return marks
    }

    /// This clip's eligible crossfade partner (m11-d): the very next ordinary
    /// AUDIO clip by start that begins at or before this clip's end (adjacent or
    /// overlapping). nil for a MIDI clip, a comp member, or when nothing sits to
    /// its right — then the "Crossfade with Next" menu stays hidden.
    private func crossfadeNeighbor(for clip: Clip, in track: Track) -> UUID? {
        guard !clip.isMIDI, clip.takeGroupID == nil else { return nil }
        let audio = track.clips
            .filter { !$0.isMIDI && $0.takeGroupID == nil }
            .sorted { $0.startBeat < $1.startBeat }
        guard let idx = audio.firstIndex(where: { $0.id == clip.id }), idx + 1 < audio.count else {
            return nil
        }
        let next = audio[idx + 1]
        let eps = 1e-6
        guard next.startBeat > clip.startBeat + eps,
              next.startBeat <= clip.startBeat + clip.lengthBeats + eps else { return nil }
        return next.id
    }

    // MARK: - Take lanes (per expanded track with groups, beat-aligned)

    private var takeLanes: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if isTakesExpanded(track) {
                TakeLanesView(
                    track: track,
                    geometry: takeGeometry,
                    contentWidth: contentWidth,
                    snap: snap,
                    meterMap: meterMap,
                    secondsPerBeat: secondsPerBeat,
                    waveformStore: waveformStore,
                    onSetComp: { groupID, segments in onSetTakeComp(track.id, groupID, segments) },
                    onSelectLane: { groupID, laneID in onSelectTake(track.id, groupID, laneID) },
                    onFlatten: { groupID in onFlattenTakeGroup(track.id, groupID) },
                    onRemoveLane: { groupID, laneID in onRemoveTakeLane(track.id, groupID, laneID) }
                )
                .frame(width: contentWidth, height: takesHeight(track), alignment: .topLeading)
                .offset(y: takesTop(index))
            }
        }
    }

    // MARK: - Automation editor rows (per expanded track, beat-aligned)

    private var automationLanes: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if isExpanded(track) {
                automationRow(for: track)
                    .frame(width: contentWidth, height: Self.automationLaneHeight)
                    .offset(y: automationTop(index))
            }
        }
    }

    @ViewBuilder
    private func automationRow(for track: Track) -> some View {
        if let lane = selectedLane(for: track), let param = AutomationParam(target: lane.target) {
            AutomationLaneEditor(
                lane: lane,
                param: param,
                geometry: AutomationGeometry(
                    pixelsPerBeat: pixelsPerBeat,
                    laneHeight: Self.automationLaneHeight,
                    range: param.range),
                contentWidth: contentWidth,
                onCommit: { points in onCommitPoints(track.id, lane.id, points) },
                // m23-ai: these editors ARE descendants of the arrange's
                // arrow-key mount, so each one must be able to say "I hold a
                // breakpoint selection, don't nudge the clip out from under me".
                // Keyed by lane id inside the bridge, which is why N of them can
                // report at once without clobbering each other.
                pointSelection: automationPointSelection
            )
            // Re-init the editor's draft when the selected lane (target) changes.
            .id(lane.id)
        } else {
            automationPlaceholder
        }
    }

    /// Shown when a track's automation row is open but no lane is chosen yet —
    /// the sidebar's target picker is where you pick one.
    private var automationPlaceholder: some View {
        ZStack {
            Rectangle().fill(DAWTheme.background.opacity(0.35))
            Text("Pick a target in the track header to automate")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Audio import drag-drop (beta m10-k)

    /// The track whose row band contains content-space `y`, or nil for the ruler /
    /// empty space below the last lane (→ a new-track import). A row spans its clip
    /// lane plus any expanded take/automation rows, so a drop anywhere in a track's
    /// vertical extent targets that track.
    private func trackIndex(atContentY y: CGFloat) -> Int? {
        guard y >= rulerInset else { return nil }
        for i in tracks.indices {
            let top = laneTop(i)
            let bottom = top + rowHeight + extraHeight(tracks[i]) + Self.laneSpacing
            if y >= top && y < bottom { return i }
        }
        return nil
    }

    /// Resolves a live drop point into its hover preview: the landing beat + the
    /// target lane (highlighted only when a SINGLE file lands on an existing
    /// audio lane — the plan's routing rule, shared so the preview never drifts
    /// from what the drop will actually do).
    ///
    /// m23-f: the ONE `ArrangeDropSnap.resolve` call. Its result is what the drop
    /// line paints AND what the import lands on — the same `ResolvedDropBeat`
    /// value travels into `AudioImportContext`, so there is no second
    /// computation to disagree with. Magnet targets are the TARGET LANE's clip
    /// edges (plus bar 1, which `ArrangeDropSnap` always offers): a drop onto a
    /// lane should be able to butt exactly against what is already on that lane,
    /// including edges the grid cannot express.
    private func resolveDropHover(at point: CGPoint,
                                  contents: ArrangeDragContents) -> AudioDropHover {
        let rawBeat = max(0, Double(point.x / max(pixelsPerBeat, 0.0001)))
        let index = trackIndex(atContentY: point.y)
        let kind = index.map { tracks[$0].kind }
        let edges: [Double] = index.map { i in
            ArrangeDropSnap.clipEdgeBeats(
                startBeats: tracks[i].clips.map(\.startBeat),
                lengthBeats: tracks[i].clips.map(\.lengthBeats))
        } ?? []
        let landing = ArrangeDropSnap.resolve(
            rawBeat: rawBeat, snap: effectiveSnap, meterMap: meterMap,
            pixelsPerBeat: Double(pixelsPerBeat), clipEdgeBeats: edges)
        // m23-k4b: `dragCarriesMIDI` flows into the SAME predicate the plan
        // executes with — a MIDI-carrying drag shows no lane highlight (a `.mid`
        // makes its own instrument tracks) while the drop LINE still shows,
        // because the landing beat is real either way.
        let landsOnLane = AudioImportPlan.routesToExistingAudioTrack(
            fileCount: contents.fileCount, targetKind: kind,
            dragCarriesMIDI: contents.carriesMIDI)
        return AudioDropHover(
            targetTrackID: index.map { tracks[$0].id },
            targetLaneIndex: landsOnLane ? index : nil,
            landing: landing,
            rawBeat: rawBeat)
    }

    /// The cyan drop affordance while a valid audio drop hovers (glow earned by
    /// state — Rule 3): a lane highlight when a single file lands on an existing
    /// audio lane, plus a drop line at the snapped landing beat (always, so a
    /// new-track drop still shows WHERE it will start).
    @ViewBuilder
    private var dropAffordance: some View {
        if let hover = dropHover {
            if let index = hover.targetLaneIndex {
                RoundedRectangle(cornerRadius: 3)
                    .fill(DAWTheme.playback.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(DAWTheme.playback.opacity(0.8), lineWidth: 1.5))
                    .frame(width: contentWidth, height: rowHeight)
                    .glow(DAWTheme.playback, radius: 6, intensity: 0.5)
                    .offset(y: laneTop(index))
                    .allowsHitTesting(false)
            }
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 2, height: contentHeight)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
                .offset(x: CGFloat(hover.snappedBeat) * pixelsPerBeat)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Playhead (offset view; no Canvas redraw on transport ticks)

    private var playhead: some View {
        Rectangle()
            .fill(DAWTheme.playback)
            .frame(width: 1.5, height: contentHeight)
            .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
            .offset(x: CGFloat(positionBeats) * pixelsPerBeat)
            .allowsHitTesting(false)
    }

    // MARK: - Pointer affordances (m17-c: grab-scrub, ghost line, click-seek)

    /// The playhead's content-space x at the live zoom.
    private var playheadX: CGFloat { CGFloat(positionBeats) * pixelsPerBeat }

    /// The lane-band geometry the headless classifier consumes — built from the
    /// SAME laneTop/rowHeight/extraHeight math the layout uses, so the zone
    /// decisions can never drift from what is actually drawn.
    private var pointerLanes: [ArrangePointerLane] {
        tracks.indices.map { i in
            let top = laneTop(i)
            return ArrangePointerLane(
                clipTop: top,
                clipBottom: top + rowHeight,
                bottom: top + rowHeight + extraHeight(tracks[i]),
                clipSpans: tracks[i].clips.map {
                    ArrangeClipSpan(startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
                })
        }
    }

    private func pointerZone(at p: CGPoint) -> ArrangePointerZone {
        ArrangePointer.zone(
            x: p.x, y: p.y,
            playheadX: playheadX,
            pixelsPerBeat: pixelsPerBeat,
            topInset: rulerInset,
            contentBottom: laneStackHeight,
            lanes: pointerLanes,
            laneSpacing: Self.laneSpacing)
    }

    /// The beat a pointer x seeks/previews: snapped on the arrange grid, or raw
    /// while ⌥ is held (the house fine-drag modifier — documented m17-c choice).
    private func pointerBeat(forX x: CGFloat) -> Double {
        ArrangePointer.beat(
            forX: x, pixelsPerBeat: pixelsPerBeat, snap: effectiveSnap,
            meterMap: meterMap,
            snapBypassed: NSEvent.modifierFlags.contains(.option))
    }

    /// A clear, full-lane-area surface UNDER the clip blocks / take lanes /
    /// automation editors: clicks that reach it are by construction on EMPTY
    /// timeline space (everything interactive hit-tests above it), extending the
    /// ruler-never-dead rule to the lanes. Its continuous hover drives the ghost
    /// line — hover is NOT occlusion-gated on this macOS (the marker-lane
    /// precedent), so the handler classifies the zone itself and only ghosts
    /// over genuinely empty space.
    private var pointerHoverSurface: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: contentWidth, height: max(0, laneStackHeight - rulerInset))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(Self.contentSpace)) { phase in
                switch phase {
                case .active(let p): handlePointerHover(at: p)
                case .ended: endPointerHover()
                }
            }
            // Two tap counts on ONE surface (m23-e). Apple's documented idiom is
            // to declare the HIGHER count FIRST — SwiftUI then gives the
            // double-tap its chance before the single tap claims the event
            // (`ExclusiveGesture` semantics, expressed with the plain modifiers
            // this file already uses for the seek). Chosen over a hand-rolled
            // `SpatialTapGesture(count: 2).exclusively(before:)` because that
            // composition delays EVERY seek by the double-click interval, and
            // click-to-seek is the far more frequent gesture; here the create
            // path is deliberately built to be correct whether or not the single
            // tap also fires (see `handleDoubleClick` — the seek and the clip
            // start read the same `pointerBeat(forX:)`).
            .onTapGesture(count: 2, coordinateSpace: .named(Self.contentSpace)) { location in
                handleDoubleClick(at: location)
            }
            .onTapGesture(coordinateSpace: .named(Self.contentSpace)) { location in
                // m23-g3: swallow the tap a marquee's own mouse-up can
                // synthesize, so releasing a rubber band never also seeks. The
                // check lives HERE, in the gesture closure, and deliberately NOT
                // inside `handleEmptyClick` — the staged path
                // (`applyPointerStage` → `handleEmptyClick`) must keep testing
                // the handler, not inherit a gesture-layer workaround it can
                // neither cause nor observe.
                if consumeMarqueeClickSuppression() { return }
                handleEmptyClick(at: location)
            }
            // The rubber band (m23-g3). SIMULTANEOUS, which is the whole
            // regression story of this item: `pointerHoverSurface` already
            // carries two tap counts whose declaration ORDER was chosen
            // deliberately (see above), and a competing `.gesture` here would
            // re-enter exactly the arbitration this file avoided on purpose. A
            // simultaneous drag does not compete with either tap — the
            // `pinchZoomGesture` precedent on the lanes ZStack, same reasoning —
            // and its `minimumDistance` means a click never arms it at all, so
            // click-to-seek (m17-c) and double-click-create (m23-e) keep their
            // events. Content space, matching both taps and `playheadScrubGesture`:
            // `laneTop` returns content-space y, and `.local` would be silently
            // right in `.lanes` (rulerInset == 0) and wrong in `.full`.
            .simultaneousGesture(marqueeGesture)
            .offset(y: rulerInset)
            .explainable(.arrangePlayhead)
    }

    // MARK: - Rubber band (m23-g3)

    /// The lane bands the marquee intersects — built from the SAME `laneTop` /
    /// `rowHeight` math the layout uses (the `pointerLanes` discipline), so the
    /// band's idea of where track 3 is can never drift from where track 3 is
    /// drawn. Clip lanes ONLY: a track's expanded take/automation rows hold no
    /// clips and are not part of the intersect surface.
    private var marqueeLanes: [ArrangeMarqueeLane] {
        tracks.indices.map { i in
            ArrangeMarqueeLane(
                clipTop: laneTop(i),
                clipBottom: laneTop(i) + rowHeight,
                clips: tracks[i].clips.map {
                    ArrangeMarqueeClip(id: $0.id, startBeat: $0.startBeat,
                                       lengthBeats: $0.lengthBeats)
                })
        }
    }

    /// Sweep a band over empty timeline space to select the clips it touches.
    ///
    /// `minimumDistance` = `ArrangeMarquee.dragSlop`, so the band ARMS only once
    /// the pointer has actually travelled: below it SwiftUI never begins this
    /// gesture, the taps run untouched, and no band is ever drawn for a click.
    ///
    /// NO ZONE GUARD, deliberately — the m23-e lesson one gesture over. Empty
    /// space within the playhead's grab tolerance classifies `.playheadGrab`, so
    /// a `pointerZone(at:) == .empty` guard would refuse a band started right
    /// where the user had just clicked (which SEEKS the playhead onto that
    /// point). The surface's own contract already guarantees emptiness —
    /// everything interactive, `playheadGrabStrips` included, hit-tests above
    /// it — so a guard here would be a second, disagreeing computation.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: ArrangeMarquee.dragSlop,
                    coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                if marqueeSession == nil {
                    // The chord is read at ARM time from the global flags — a
                    // `DragGesture` hands its handler no event, the same
                    // constraint (and the same remedy) as
                    // `ArrangeClickModifiers.current`. Routed through the ONE
                    // chord→intent mapping, so shift/⌘ mean the same thing on a
                    // band as on a click and there is no second chord table.
                    beginMarquee(
                        at: value.startLocation,
                        additive: ArrangeClickIntent.intent(for: .current) == .toggle)
                }
                updateMarquee(to: value.location)
            }
            .onEnded { value in endMarquee(at: value.location) }
    }

    /// Arms a marquee: fix the band's origin corner and freeze the selection the
    /// gesture measures against.
    private func beginMarquee(at origin: CGPoint, additive: Bool) {
        marqueeSession = MarqueeSession(origin: origin, base: selection.ids, additive: additive)
    }

    /// Re-decides the selection for the band's current free corner. Runs on
    /// EVERY update, from the frozen base — so growing the band adds clips and
    /// shrinking it gives them back.
    @discardableResult
    private func updateMarquee(to point: CGPoint) -> Set<UUID> {
        guard let session = marqueeSession else { return [] }
        let band = ArrangeMarquee.band(from: session.origin, to: point)
        let hits = ArrangeMarquee.hits(band: band, lanes: marqueeLanes,
                                       pixelsPerBeat: pixelsPerBeat)
        marqueeBand = band
        onMarqueeSelect?(hits, session.base, session.additive)
        // Reported LAST, so the state it announces is already stored (the
        // `arrangePointerReportSeq` rule).
        onMarqueeState?(band, hits)
        return hits
    }

    /// Commits the final band and puts the band layer away.
    private func endMarquee(at point: CGPoint) {
        guard let session = marqueeSession else { return }
        let band = ArrangeMarquee.band(from: session.origin, to: point)
        let hits = ArrangeMarquee.hits(band: band, lanes: marqueeLanes,
                                       pixelsPerBeat: pixelsPerBeat)
        onMarqueeSelect?(hits, session.base, session.additive)
        marqueeSession = nil
        marqueeBand = nil
        // Arm the click suppression ONLY for a band that actually swept area.
        // A degenerate release drew nothing and selected nothing, so there is no
        // stray seek to swallow — and swallowing one anyway would eat the user's
        // next click for a gesture that did nothing. NOT OBSERVABLE FROM ANY
        // SEAM, and recorded here rather than left to be rediscovered: the
        // staged pointer path calls `handleEmptyClick` directly and never runs
        // the tap closure this flag lives in, so a gate leg for it could only
        // pass vacuously.
        if band.width > 0 || band.height > 0 { marqueeEndedAt = Date() }
        // ONE final report: band gone, selection final. A gate reading this
        // cannot mistake "the band was never drawn" for "the band is put away",
        // because the mid-drag reports carried a non-nil rect.
        onMarqueeState?(nil, hits)
    }

    /// True when this tap is the echo of a marquee release and must not seek.
    /// CONSUMED on the first tap either way, and time-bounded, so a stale flag
    /// can never swallow a later deliberate click.
    private func consumeMarqueeClickSuppression() -> Bool {
        guard let endedAt = marqueeEndedAt else { return false }
        marqueeEndedAt = nil
        return Date().timeIntervalSince(endedAt) < Self.marqueeClickSuppressWindow
    }

    /// Runs a debug-staged marquee step through the live handlers. `.ruler`
    /// instances carry no pointer layer, so they ignore the stage (exactly one
    /// instance reacts per staging).
    private func applyMarqueeStage(_ stage: ArrangeMarqueeStage?) {
        guard let stage, content != .ruler else { return }
        let p = CGPoint(x: stage.x, y: stage.y)
        switch stage.action {
        case .begin:
            beginMarquee(at: p, additive: stage.additive)
            // Apply immediately, exactly as the real gesture does the instant it
            // arms: a degenerate band selects nothing, so a plain marquee
            // clears the previous selection at press.
            updateMarquee(to: p)
        case .changed:
            updateMarquee(to: p)
        case .end:
            endMarquee(at: p)
        }
    }

    /// The band itself: a translucent cyan wash with a thin bright edge and an
    /// earned glow (docs/DESIGN-LANGUAGE.md — cyan is active state, the glow
    /// recipe is core + bloom, and nothing static ever glows; this exists only
    /// while a gesture is live). Hit-test-inert, so it can never eat the drag
    /// that is drawing it.
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

    private func handlePointerHover(at p: CGPoint) {
        // m23-f: an ordinary pointer event over the lanes dismisses a STRANDED
        // drop overlay. A drop line is armed and cleared only by OS drag
        // callbacks; if a terminating one never arrives (measured: the app
        // deactivating with a hover in flight strands it permanently) the line
        // is hit-test-inert and the user has no way to remove it. This gives
        // them one: move the mouse. Guarded on the mouse button inside the core,
        // so it can never cancel a preview during a live drag.
        if laneDropCore.dismissStrandedHover(pressedMouseButtons: NSEvent.pressedMouseButtons) {
            // Reported SYNCHRONOUSLY, not left to the `.onChange` above: the
            // seam answers as soon as the pointer stage has run, and a mirror
            // that updates a SwiftUI pass later would still be showing the
            // dismissed line at that moment.
            onDropHoverChange?(nil)
        }
        let zone = pointerZone(at: p)
        let ghost = zone == .empty ? pointerBeat(forX: p.x) : nil
        if ghostBeat != ghost { ghostBeat = ghost }
        onPointerState?(zone, ghost)
    }

    private func endPointerHover() {
        if ghostBeat != nil { ghostBeat = nil }
        onPointerState?(.outside, nil)
    }

    /// Click on empty lane space seeks (m17-c #3). The zone guard is
    /// belt-and-suspenders — a click over a clip/editor never reaches this
    /// surface — and keeps the STAGED path (which bypasses hit-testing) honest:
    /// a staged click over a clip is refused the same way a real one is.
    private func handleEmptyClick(at p: CGPoint) {
        guard pointerZone(at: p) == .empty else { return }
        onSeek(pointerBeat(forX: p.x))
    }

    /// Double-click in the lanes. TWO destinations, decided by what is under the
    /// point — and deliberately NOT by `pointerZone`:
    ///
    ///   - over a CLIP → split at the snapped beat (m17-c). Pro-only, exactly
    ///     like `ClipBlock`'s own gesture; this is the staged twin of it (a real
    ///     double-click on a block runs the block's gesture, since the block
    ///     hit-tests above the pointer surface), routed through the SAME
    ///     `ClipEdit.snappedSplit` math and the SAME `onSplitClip` callback
    ///     (→ `ProjectStore.splitClip`, the `clip.split` wire method).
    ///   - over EMPTY lane space → create a MIDI clip there and open the note
    ///     editor on it (m23-e). Available in BOTH densities: this is the
    ///     beginner's only path from a fresh instrument track to a writable
    ///     grid, so gating it on Pro would defeat the item.
    ///
    /// Why not `pointerZone(at:) == .empty` for the create: inside a clip band
    /// the classifier checks the playhead-grab tolerance BEFORE the clip lookup,
    /// so empty space within 4 pt of the playhead reads `.playheadGrab`. A real
    /// double-click whose first tap also seeks (see `pointerHoverSurface`) MOVES
    /// the playhead onto the pointer — a zone guard would then refuse exactly
    /// the beat the user just clicked, while the staged path (which never seeks)
    /// passed. Resolving the lane band + asking `clipIndex` directly is
    /// independent of both the playhead and SwiftUI's gesture arbitration.
    private func handleDoubleClick(at p: CGPoint) {
        guard let laneIndex = ArrangePointer.clipLaneIndex(atY: p.y, in: pointerLanes) else { return }
        let track = tracks[laneIndex]
        let beatRaw = Double(p.x / max(pixelsPerBeat, 0.0001))
        let spans = track.clips.map {
            ArrangeClipSpan(startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
        }
        if let clipIndex = ArrangePointer.clipIndex(atBeat: beatRaw, in: spans) {
            guard isPro else { return }
            let clip = track.clips[clipIndex]
            if let beat = ClipEdit.snappedSplit(
                timelineBeatRaw: beatRaw, clipStart: clip.startBeat,
                clipLength: clip.lengthBeats, snap: effectiveSnap, meterMap: meterMap) {
                onSplitClip(track.id, clip, beat)
            }
            return
        }
        // Empty space: start writing notes here. The start beat comes from the
        // SAME `pointerBeat(forX:)` a single click seeks with — so however
        // SwiftUI arbitrates the two tap counts (double only, or single-then-
        // double), the clip start and the playhead agree by construction.
        let beat = pointerBeat(forX: p.x)
        guard let length = ArrangePointer.createClipLength(
            startBeat: beat,
            beatsPerBar: meterMap.beatsPerBar(atBeat: beat),
            spans: spans) else { return }
        onCreateMIDIClip(track.id, beat, length)
    }

    /// Runs a debug-staged pointer event through the live handlers. `.ruler`
    /// instances carry no pointer layer, so they ignore the stage (exactly one
    /// instance reacts per staging).
    private func applyPointerStage(_ stage: ArrangePointerStage?) {
        guard let stage, content != .ruler else { return }
        let p = CGPoint(x: stage.x, y: stage.y)
        switch stage.action {
        case .hover: handlePointerHover(at: p)
        case .click:
            handlePointerHover(at: p)
            handleEmptyClick(at: p)
        case .doubleClick:
            handlePointerHover(at: p)
            handleDoubleClick(at: p)
        case .clear: endPointerHover()
        }
    }

    /// The LANE-anchored refusal bubble (m23-e): a double-click that asked for a
    /// MIDI clip on a lane that cannot hold one (audio/bus) surfaces the store's
    /// message VERBATIM — the SAME string `clip.addMIDI` returns over the wire —
    /// right where it was attempted. There is no clip to hang it from (that is
    /// precisely what was refused), so it hangs on the lane at the attempted
    /// beat, clamped into the content so the message is never pushed off-screen.
    /// A silent no-op here would be the bug the item exists to fix, one surface
    /// over: nothing happens and nothing says why.
    @ViewBuilder
    private var laneRefusalBubble: some View {
        if let refusal = splitRefusal, let anchor = refusal.laneAnchor,
           let index = tracks.firstIndex(where: { $0.id == anchor.trackID }) {
            let rawX = CGFloat(anchor.beat) * pixelsPerBeat
            let maxX = max(0, contentWidth - ArrangeRefusalBubble.width - 24)
            ArrangeRefusalBubble(message: refusal.message)
                .offset(x: min(max(0, rawX), maxX), y: laneTop(index) + rowHeight / 2)
        }
    }

    /// The empty-lane hint (m23-v): a dim, calm "Double-click to add a clip" on
    /// every instrument lane that holds no clips — the VISIBLE half of m23-e.
    ///
    /// Drawn like the hover ghost line and for the same reason: `textFaint` (the
    /// measured placeholder/decorative FLOOR of the text hierarchy — a hint is
    /// exactly what that token exists for, and reaching for the token rather than
    /// an ad-hoc `.opacity()` on a brighter one is the design-language rule), no
    /// glow, no accent — never cyan (earned active transport state), never violet
    /// (AI content only). Glow is earned by state, not by a hint. It sits on
    /// EVERY empty instrument lane at once, so anything louder becomes noise in a
    /// project with several fresh tracks.
    ///
    /// `.allowsHitTesting(false)` is LOAD-BEARING, not tidiness: this layer sits
    /// above `pointerHoverSurface`, and a hit-testable label would swallow the
    /// very double-click it advertises. `.fixedSize()` keeps it on one line at
    /// any content width.
    ///
    /// Left-anchored in CONTENT space (not pinned to the viewport): a lane's ink
    /// scrolls with its lane, the way clips do, and beat 0 is where a new project
    /// opens — which is the moment this hint is for. Scrolled far right it goes
    /// with the rest of the lane's content, deliberately.
    ///
    /// **Explain copy**: the card is `.arrangePlayhead`, already anchored on
    /// `pointerHoverSurface` — the surface this hint sits over, so hovering the
    /// hint hovers the card's anchor. Its body already teaches this exact action
    /// ("Double-click empty space on an instrument track to start a clip and open
    /// the note editor"), and the catalogue forbids two entries with
    /// near-identical copy (`ExplainModel.swift`). A second id would also be
    /// unhoverable here by construction, since this layer must not hit-test.
    @ViewBuilder
    private var emptyLaneHintLayer: some View {
        // Composed ONCE. The ForEach draws this array and the reporter announces
        // this array — see `onEmptyLaneHints` for why that is the whole point.
        let hints = emptyLaneHints
        ZStack(alignment: .topLeading) {
            ForEach(hints) { hint in
                Text(hint.text)
                    .font(.system(size: Self.emptyLaneHintFontSize))
                    .foregroundStyle(DAWTheme.textFaint)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: Self.emptyLaneHintInsetX,
                            y: laneTop(hint.laneIndex) + (rowHeight - Self.emptyLaneHintFontSize) / 2 - 2)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: hints, initial: true) { _, value in onEmptyLaneHints?(value) }
    }

    /// The hints this view draws — `[Track]` in, nothing else (the headless home
    /// takes no transport, so "a track added mid-playback still shows the hint"
    /// is structural rather than promised).
    private var emptyLaneHints: [ArrangeEmptyLaneHint] {
        ArrangeEmptyLaneHints.hints(for: tracks)
    }

    /// The hover ghost line (m17-c #2): a faint NEUTRAL hairline at the
    /// pointer's snapped beat while hovering empty timeline space. Deliberately
    /// un-playhead-like — 1 pt `textSecondary` at low opacity, NO glow, never
    /// cyan — so it can never be confused with the glowing playhead (glow is
    /// earned by transport state, not by a hover hint).
    @ViewBuilder
    private var ghostLine: some View {
        if let ghostBeat {
            Rectangle()
                .fill(DAWTheme.textSecondary.opacity(0.35))
                .frame(width: 1, height: max(0, laneStackHeight - rulerInset))
                .offset(x: CGFloat(ghostBeat) * pixelsPerBeat, y: rulerInset)
                .allowsHitTesting(false)
        }
    }

    /// The playhead grab strips (m17-c #1): narrow clear segments over each
    /// track's CLIP band plus the free space below the lanes, centered on the
    /// playhead — hovering shows the open hand, dragging scrub-seeks. Segments
    /// (not one full-height strip) so the take-lane / automation editors keep
    /// their full pointer surface at the playhead x; the headless classifier
    /// mirrors exactly this coverage.
    @ViewBuilder
    private var playheadGrabStrips: some View {
        let tol = ArrangePointer.playheadGrabTolerance
        let stripWidth = tol * 2 + 1.5   // tolerance each side of the 1.5 pt line
        let stripX = playheadX - tol
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, _ in
            Rectangle()
                .fill(Color.clear)
                .frame(width: stripWidth, height: rowHeight)
                .contentShape(Rectangle())
                .hoverCursor(ArrangePointer.cursor(for: .playheadGrab) ?? .grab)
                .gesture(playheadScrubGesture)
                .offset(x: stripX, y: laneTop(index))
        }
        let tailTop = tracks.indices.last.map {
            laneTop($0) + rowHeight + extraHeight(tracks[$0]) + Self.laneSpacing
        } ?? rulerInset
        if laneStackHeight > tailTop {
            Rectangle()
                .fill(Color.clear)
                .frame(width: stripWidth, height: laneStackHeight - tailTop)
                .contentShape(Rectangle())
                .hoverCursor(ArrangePointer.cursor(for: .playheadGrab) ?? .grab)
                .gesture(playheadScrubGesture)
                .offset(x: stripX, y: tailTop)
        }
    }

    /// Grab-and-scrub the playhead: the drag reads the stationary content space
    /// (the strip relocates under the pointer as seeks land — the ClipBlock
    /// "don't feed your own motion back" rule), seeks per tick on the SNAP grid
    /// (⌥ = unsnapped fine scrub), and holds the closed hand for the whole
    /// drag. A press that never crosses the slop is a click and does nothing —
    /// grabbing the playhead must not jump it.
    private var playheadScrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                if !playheadScrubbing {
                    guard abs(value.translation.width) > ArrangePointer.scrubSlop else { return }
                    playheadScrubbing = true
                }
                DragCursor.set(ArrangePointer.cursor(for: .playheadGrab, dragging: true) ?? .grabbing)
                onSeek(pointerBeat(forX: value.location.x))
            }
            .onEnded { _ in
                playheadScrubbing = false
                DragCursor.clear()
            }
    }

    // MARK: - Loop region band + ruler (beta m10-g)

    /// The committed loop region, or nil when none exists — the transport model
    /// always keeps `end > start` once set, so nil is the untouched/preview case
    /// (0…0). nil renders no band and makes the whole ruler a sketch/seek surface.
    private var loopRegion: LoopRegion? {
        loopEndBeat > loopStartBeat ? LoopRegion(start: loopStartBeat, end: loopEndBeat) : nil
    }

    private var loopGeometry: LoopRulerGeometry {
        LoopRulerGeometry(pixelsPerBeat: pixelsPerBeat)
    }

    /// The region the band DRAWS: the live drag preview while a gesture is in
    /// flight (so create/resize/move update as the pointer moves), else the
    /// committed region. A CREATE drag is REPLACING, so it shows only its own
    /// preview (nil = nothing yet, no flash of the old region); resize/move always
    /// carry a preview, with the committed region as a safety fallback.
    private var displayLoopRegion: LoopRegion? {
        guard let drag = loopDrag else { return loopRegion }
        return drag.mode == .create ? drag.preview : (drag.preview ?? loopRegion)
    }

    /// Cyan glow only when EARNED: the loop is enabled, or a create drag is live
    /// (you're actively sketching a loop that will be enabled on commit). A
    /// resize/move of a disabled region stays a dim outline — honest to its state.
    private var displayLoopEnabled: Bool {
        if let drag = loopDrag { return drag.mode == .create ? true : isLoopEnabled }
        return isLoopEnabled
    }

    /// The loop band, drawn in the top strip of the ruler. Cyan (playback accent)
    /// glowing when enabled; a dim low-opacity outline when a region exists but
    /// looping is off; nothing when no region. Non-interactive — the gestures live
    /// on `loopRuler` (a full-ruler-height clear surface) so the glow never blocks
    /// a press (docs/DESIGN-LANGUAGE.md: glow only when earned, cyan = active).
    @ViewBuilder
    private var loopBand: some View {
        if let region = displayLoopRegion {
            let startX = CGFloat(region.start) * pixelsPerBeat
            let w = max(3, CGFloat(region.end - region.start) * pixelsPerBeat)
            let enabled = displayLoopEnabled
            let accent = DAWTheme.playback
            RoundedRectangle(cornerRadius: 2)
                .fill(accent.opacity(enabled ? 0.22 : 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(accent.opacity(enabled ? 0.85 : 0.35), lineWidth: 1)
                )
                .overlay(alignment: .leading) { loopEdgeHandle(enabled: enabled) }
                .overlay(alignment: .trailing) { loopEdgeHandle(enabled: enabled) }
                .frame(width: w, height: Self.loopBandHeight)
                .glow(accent, radius: 5, intensity: enabled ? 0.5 : 0)
                .offset(x: startX, y: Self.loopBandTop)
                .allowsHitTesting(false)
        }
    }

    /// A brighter cyan tick at a band edge — advertises the resize grip (aligned
    /// with `LoopRulerGeometry.edgeTolerance`'s grab strip).
    private func loopEdgeHandle(enabled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(DAWTheme.playback.opacity(enabled ? 0.95 : 0.5))
            .frame(width: 3, height: Self.loopBandHeight)
    }

    /// A full-ruler-height clear surface carrying the loop gestures + hover cursor
    /// (beta m10-g). Sits atop the ruler area only (y 0…rulerHeight, above the clip
    /// lanes) so it never blocks a clip. One `DragGesture(minimumDistance: 0)`
    /// handles BOTH the click (no movement past the slop → toggle/seek) and every
    /// drag mode (sketch/resize/move) — the piano-roll grid single-gesture idiom.
    private var loopRuler: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: contentWidth, height: Self.rulerHeight)
            .contentShape(Rectangle())
            .hoverCursor(resolve: loopRulerCursor)
            .gesture(loopRulerGesture)
            .explainable(.loopRuler)
            .help("Loop ruler — drag to set the loop region, click inside to toggle looping, click empty to move the playhead")
    }

    /// Rest cursor over the ruler: mirror the gesture's zone routing so the hover
    /// cue matches what a press would do — the region's edges resize, its body
    /// grabs, the empty ruler is a horizontal position surface.
    private func loopRulerCursor(at p: CGPoint) -> CursorKind? {
        CursorAffordance.forLoopZone(loopGeometry.classify(contentX: p.x, region: loopRegion))
    }

    /// One drag gesture for the whole ruler. `loopDrag == nil` at end means the
    /// press never exceeded the click slop → it's a click (toggle/seek); otherwise
    /// it committed a sketched/resized/moved region.
    private var loopRulerGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                // Below the slop it's still a potential click — don't begin a drag.
                if loopDrag == nil {
                    guard abs(value.translation.width) > Self.loopClickSlop else { return }
                    _ = beginLoopDrag(atStartX: value.startLocation.x)
                }
                guard let state = loopDrag else { return }
                let curX = value.location.x
                let preview: LoopRegion?
                switch state.mode {
                case .create:
                    preview = LoopEdit.createRegion(
                        anchorBeat: state.anchorBeat, currentBeat: loopGeometry.beat(forX: curX),
                        snap: effectiveSnap, meterMap: meterMap)
                    DragCursor.set(.resizeLeftRight)
                case .resizeStart:
                    preview = LoopEdit.resizedStart(
                        region: state.origin, newStartRaw: loopGeometry.beat(forX: curX),
                        snap: effectiveSnap, meterMap: meterMap)
                    DragCursor.set(.resizeLeftRight)
                case .resizeEnd:
                    preview = LoopEdit.resizedEnd(
                        region: state.origin, newEndRaw: loopGeometry.beat(forX: curX),
                        snap: effectiveSnap, meterMap: meterMap)
                    DragCursor.set(.resizeLeftRight)
                case .move:
                    let delta = Double((curX - value.startLocation.x) / pixelsPerBeat)
                    preview = LoopEdit.movedRegion(
                        region: state.origin, dragDeltaBeats: delta,
                        snap: effectiveSnap, meterMap: meterMap)
                    DragCursor.set(.grabbing)
                }
                loopDrag?.preview = preview
            }
            .onEnded { value in
                defer { loopDrag = nil; DragCursor.clear() }
                if let state = loopDrag {
                    switch state.mode {
                    case .create:
                        if let region = state.preview {
                            onSetLoop(true, region.start, region.end)
                        } else {
                            // A drag that never crossed a snap boundary is a click: seek.
                            onSeek(effectiveSnap.snap(
                                beat: loopGeometry.beat(forX: value.startLocation.x),
                                meterMap: meterMap))
                        }
                    case .resizeStart, .resizeEnd, .move:
                        if let region = state.preview {
                            onSetLoop(isLoopEnabled, region.start, region.end)
                        }
                    }
                } else {
                    // Never exceeded the slop → a click on the ruler.
                    switch LoopEdit.click(contentX: value.location.x, region: loopRegion,
                                          geometry: loopGeometry, snap: effectiveSnap,
                                          meterMap: meterMap) {
                    case .toggle:
                        if let region = loopRegion { onSetLoop(!isLoopEnabled, region.start, region.end) }
                    case .seek(let beat):
                        onSeek(beat)
                    }
                }
            }
    }

    /// Classifies the press point and captures the drag origin so per-tick math is
    /// stable. Create anchors on the raw press beat; resize/move capture the
    /// committed region (a create with no region uses a zero-width anchor origin).
    private func beginLoopDrag(atStartX startX: CGFloat) -> LoopDragState {
        let mode: LoopDragMode
        switch loopGeometry.classify(contentX: startX, region: loopRegion) {
        case .edgeStart: mode = .resizeStart
        case .edgeEnd:   mode = .resizeEnd
        case .body:      mode = .move
        case .empty:     mode = .create
        }
        let anchor = loopGeometry.beat(forX: startX)
        let origin = loopRegion ?? LoopRegion(start: anchor, end: anchor)
        let state = LoopDragState(mode: mode, origin: origin, anchorBeat: anchor,
                                  preview: mode == .create ? nil : origin)
        loopDrag = state
        return state
    }

    // MARK: - Session marker lane (m11-c)

    private var markerGeometry: MarkerLaneGeometry {
        MarkerLaneGeometry(pixelsPerBeat: pixelsPerBeat)
    }

    /// The beat a marker's flag DRAWS at: its live drag preview while a move is in
    /// flight, else its committed beat. Keeps the flag under the cursor during a
    /// scrub without waiting for the store round-trip.
    private func displayBeat(for marker: Marker) -> Double {
        if let drag = markerDrag, drag.markerID == marker.id { return drag.previewBeat }
        return marker.beat
    }

    /// The marker lane: a background surface in the marker strip that carries the
    /// "Add Marker Here" context menu (and a click-to-seek so the strip is never a
    /// dead surface), plus one interactive flag per marker layered on top. Sits
    /// ABOVE the loop ruler in the ZStack but occupies ONLY the marker strip, so it
    /// carves that band out of the loop gesture surface without touching the loop
    /// band or the seek area (m10-g gestures keep working — regression-pinned).
    private var markerLane: some View {
        ZStack(alignment: .topLeading) {
            // Add-here surface: fills the marker strip, records the hover beat, and
            // seeks on a plain click (the ruler-never-dead rule). Right-click adds.
            Rectangle()
                .fill(Color.clear)
                .frame(width: contentWidth, height: Self.markerLaneHeight)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .named(Self.contentSpace)) { phase in
                    if case .active(let p) = phase {
                        markerAddHoverBeat = effectiveSnap.snap(
                            beat: markerGeometry.beat(forX: p.x), meterMap: meterMap)
                    }
                }
                .onTapGesture(coordinateSpace: .named(Self.contentSpace)) { location in
                    onSeek(effectiveSnap.snap(beat: markerGeometry.beat(forX: location.x),
                                              meterMap: meterMap))
                }
                .contextMenu {
                    Button("Add Marker Here") { onAddMarker(markerAddHoverBeat) }
                }
                .offset(y: Self.markerLaneTop)

            ForEach(markers) { marker in
                markerFlag(marker)
            }
        }
        .explainable(.sessionMarkers)
    }

    // MARK: - Tempo lane (m12-d)

    /// The tempo lane strip, layered over the loop ruler and occupying ONLY the
    /// tempo strip (like the marker lane), so a press here edits the tempo map
    /// instead of the loop. Reads the resolved maps by value (live wire sync) and
    /// drives every edit through the shared `tempoLane` model → `setTempoMap`.
    private var tempoLaneView: some View {
        TempoLaneBand(
            model: tempoLane,
            tempoMap: tempoMap,
            meterMap: meterMap,
            pixelsPerBeat: pixelsPerBeat,
            height: Self.tempoLaneHeight,
            contentWidth: contentWidth,
            snap: effectiveSnap,
            isPro: isPro,
            isRecording: isRecordingTransport,
            contentSpace: Self.contentSpace
        )
        .offset(y: Self.tempoLaneTop)
    }

    @ViewBuilder
    private func markerFlag(_ marker: Marker) -> some View {
        MarkerFlag(
            name: marker.name,
            height: Self.markerLaneHeight,
            isRenaming: renamingMarkerID == marker.id,
            onSeek: { onSeek(marker.beat) },
            onBeginRename: { beginMarkerRename(marker) },
            onCommitRename: { draft in
                renamingMarkerID = nil
                // Reuse the tested track-rename commit rule (trim / empty-cancel /
                // unchanged-no-op); the store also enforces it, belt-and-suspenders.
                if let name = TrackRename.committedName(draft: draft, current: marker.name) {
                    onRenameMarker(marker.id, name)
                }
            },
            onCancelRename: { renamingMarkerID = nil },
            onRemove: { onRemoveMarker(marker.id) },
            onDragChanged: { translationWidth in
                // First tick past the slop begins the drag and CAPTURES the origin
                // beat, so subsequent ticks measure the FULL translation off that
                // fixed anchor (never the live, self-updating marker.beat — the
                // ClipBlock "don't feed your own motion back" rule).
                if markerDrag == nil {
                    guard abs(translationWidth) > Self.loopClickSlop else { return }
                    markerDrag = MarkerDragState(markerID: marker.id, originBeat: marker.beat,
                                                 previewBeat: marker.beat)
                }
                guard let drag = markerDrag, drag.markerID == marker.id else { return }
                let delta = Double(translationWidth / pixelsPerBeat)
                let beat = MarkerLaneEdit.movedBeat(
                    originBeat: drag.originBeat, dragDeltaBeats: delta,
                    snap: effectiveSnap, meterMap: meterMap)
                markerDrag?.previewBeat = beat
                onMoveMarker(marker.id, beat)   // coalesces to one undo step
                DragCursor.set(.grabbing)
            },
            onDragEnded: { _ in
                // A press that never crossed the slop left `markerDrag` nil → it was
                // a click, so seek to the flag (the ruler-never-dead rule).
                let wasClick = markerDrag?.markerID != marker.id
                markerDrag = nil
                DragCursor.clear()
                if wasClick { onSeek(marker.beat) }
            }
        )
        // Anchor the flag by its left edge at the marker's (live) beat, seated in
        // the marker strip. A drag reads the stationary content space so the flag
        // never feeds its own motion back (the ClipBlock idiom).
        .offset(x: markerGeometry.x(forBeat: displayBeat(for: marker)), y: Self.markerLaneTop)
    }

    /// Opens the inline rename field on a marker's flag (double-click / menu).
    private func beginMarkerRename(_ marker: Marker) {
        renamingMarkerID = marker.id
    }
}

/// A loop-ruler drag in flight (beta m10-g). Captured on the first tick that
/// crosses the click slop so per-tick math is stable; `preview` is the live
/// proposed region the band renders (nil during a sub-threshold create).
private enum LoopDragMode: Equatable { case create, resizeStart, resizeEnd, move }

private struct LoopDragState: Equatable {
    var mode: LoopDragMode
    /// The region at drag start (create: a zero-width anchor when none exists).
    var origin: LoopRegion
    /// Create anchor — the raw (unsnapped) press beat.
    var anchorBeat: Double
    /// The live proposed region (nil = sub-threshold create → no band, click on end).
    var preview: LoopRegion?
}

/// A marker-flag drag in flight (m11-c). Captured on the first tick past the click
/// slop so per-tick math measures the full translation off a FIXED origin (the
/// live marker.beat updates as moves commit, so it can't be the anchor).
private struct MarkerDragState: Equatable {
    var markerID: UUID
    /// The marker's beat at drag start — the fixed anchor for the translation.
    var originBeat: Double
    /// The live proposed beat the flag renders at during the scrub.
    var previewBeat: Double
}

/// One session marker as an interactive flag in the arrange ruler's marker lane
/// (m11-c): a neutral dark-glass chip with the name (SF Pro — a name is prose, not
/// a numeric readout) and an anchor bar at its exact beat. Markers are NOT AI and
/// NOT an active transport state, so the flag is deliberately NEUTRAL — no cyan, no
/// violet (docs/DESIGN-LANGUAGE.md: cyan = earned active, violet = AI only). Drag
/// to move, click to seek there, double-click or the context menu to rename in
/// place, the context menu to delete. Thin over the parent's callbacks (each wired
/// to one `ProjectStore` marker method, so undo/coalescing come free).
private struct MarkerFlag: View {
    var name: String
    var height: CGFloat
    var isRenaming: Bool
    var onSeek: () -> Void
    var onBeginRename: () -> Void
    var onCommitRename: (_ draft: String) -> Void
    var onCancelRename: () -> Void
    var onRemove: () -> Void
    /// Live drag translation (points) — the parent decides slop/anchor/commit.
    var onDragChanged: (_ translationWidth: CGFloat) -> Void
    var onDragEnded: (_ translationWidth: CGFloat) -> Void

    @State private var draft = ""
    /// True once this rename has committed or cancelled, so the focus-loss handler
    /// can't fire a second action (the TrackListView rename guard idiom).
    @State private var renameResolved = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if isRenaming { renameField } else { flagChip }
        }
    }

    /// The neutral flag chip: an anchor bar at the beat (leading edge) + the name.
    private var flagChip: some View {
        Text(name.isEmpty ? "Marker" : name)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DAWTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .frame(height: height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(DAWTheme.panelRaised.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.hairline, lineWidth: 1))
            )
            // The anchor bar marks the marker's exact beat (the chip's leading edge,
            // where the parent offsets it). textSecondary — neutral, not cyan.
            .overlay(alignment: .leading) {
                Rectangle().fill(DAWTheme.textSecondary).frame(width: 2)
            }
            .contentShape(Rectangle())
            .help("\(name) — drag to move, click to jump here, double-click to rename")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineLanesView.contentSpace))
                    .onChanged { onDragChanged($0.translation.width) }
                    .onEnded { onDragEnded($0.translation.width) }
            )
            // Double-click renames; simultaneous so the drag still recognizes a
            // single click (→ seek). The context menu is the guaranteed twin.
            .simultaneousGesture(TapGesture(count: 2).onEnded { onBeginRename() })
            .contextMenu {
                Button("Rename Marker") { onBeginRename() }
                Button("Delete Marker", role: .destructive) { onRemove() }
            }
    }

    /// The inline rename field (the TrackListView rename idiom): SF Pro dark-glass,
    /// a cyan-tinted focus border (a name is prose, cyan = focus/active), Return /
    /// focus-loss commits, Escape cancels, empty/unchanged = no-op (the store's
    /// `renameMarker` re-applies the rule too).
    private var renameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DAWTheme.textPrimary)
            .frame(width: 84, height: height)
            .padding(.horizontal, 5)
            .background(DAWTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.playback.opacity(0.6), lineWidth: 1))
            .focused($fieldFocused)
            .onAppear { draft = name; renameResolved = false; fieldFocused = true }
            .onSubmit { commit() }
            .onKeyPress(.escape) { renameResolved = true; onCancelRename(); return .handled }
            .onChange(of: fieldFocused) { _, focused in
                if !focused && !renameResolved { commit() }
            }
    }

    private func commit() {
        guard !renameResolved else { return }
        renameResolved = true
        onCommitRename(draft)
    }
}

/// One clip as an interactive rounded block (M5 i-d): drag the body to move, the
/// edges to trim, the top-corner grips to fade, double-click to split; audio
/// clips draw a peak-outline waveform windowed by `startOffsetSeconds` under
/// translucent fade shading, and a subtle SF Mono dB gain readout. Thin over the
/// headless `ClipEditGeometry`/`ClipEdit` — all mutations go out through the
/// callbacks (each wired to one `ProjectStore` clip method, so undo/coalescing
/// come free). Every drag reads its translation in the stationary content space
/// so a moving block never feeds its own offset back (the AutomationLaneEditor
/// baseline idiom, one level up for a block that relocates as it edits).
private struct ClipBlock: View {
    var clip: Clip
    var trackID: UUID
    var tint: Color
    /// A MEMBER of the arrange selection — drives the selected LOOK only (fill,
    /// stroke, glow). True on every clip of a multi-selection.
    var isSelected: Bool
    /// The FOCUS clip — drives the single-target editing affordances (the gain
    /// chip and the gain-envelope breakpoint overlay), never the look.
    ///
    /// Split from `isSelected` at m23-g1 for a concrete reason: those two
    /// affordances are EDITABLE overlays that take a single target. Letting them
    /// follow set membership would paint three draggable breakpoint lines the
    /// moment a user selects three audio clips — visually confusing, and an
    /// invitation to edit a curve on a clip the editor isn't pointed at.
    var isFocused: Bool
    /// How many clips the arrange selection holds (m23-cf) — read ONLY to title
    /// the context menu's Delete entry, never to draw. A THIRD selection input
    /// beside `isSelected`/`isFocused` because the menu needs the SIZE of the set
    /// this clip may belong to, which neither of those carries: "Delete 3 Clips"
    /// is the user's only warning of the blast radius they are about to accept.
    var arrangeSelectionCount: Int = 0
    var width: CGFloat
    var height: CGFloat
    /// This clip lane's top y in content space — lets a drag classify its start
    /// point without knowing where the parent stacked it.
    var laneOriginY: CGFloat
    var geometry: ClipEditGeometry
    var snap: ClipSnap
    /// Arrange density (docs/DESIGN-LANGUAGE.md "Panels"): Pro is the full clip-edit
    /// layer; Simple drops the trim/fade/split/gain/stretch chrome and gestures so
    /// the block is a move-only body on the (Bar-locked) grid.
    var pro: Bool
    /// The project meter map (m13-h): every move/trim/split/stretch snap routes
    /// through it, so a drag INTO a different time-signature region snaps on that
    /// region's grid (`.bar` via `MeterMap.nearestBarline`). Trivial single-meter
    /// maps reproduce the old base-meter behavior exactly.
    var meterMap: MeterMap
    var secondsPerBeat: Double
    var playheadBeat: Double
    /// True for an AUDIO clip whose span crosses a non-trivial tempo boundary
    /// (m12-d, design §3.5): its material streams at its natural rate through the
    /// change (no time-stretch), so beat-alignment inside it shifts — an amber
    /// honesty hint, never a hard block. MIDI clips never set this.
    var crossesTempoBoundary: Bool = false
    /// Nil for MIDI clips, or an audio clip whose peaks are still loading.
    var waveformPeaks: WaveformPeaks?
    /// Coarse offline-stretch render state (M5 ii-e): shimmer while pending, red
    /// accent on failure, nothing otherwise.
    var renderVisual: ClipRenderVisual
    var onSelect: (ArrangeClickModifiers) -> Void
    /// A body drag (m23-g2): reports this clip's start at DRAG BEGIN plus the
    /// RAW, pre-snap pointer translation, and returns the ACHIEVED anchor start
    /// so the readout can show what happened rather than what was asked for.
    var onMove: (_ anchorOriginalStart: Double, _ rawDragDeltaBeats: Double) -> Double
    var onTrim: (_ newStart: Double, _ newLength: Double) -> Void
    /// Fits the clip's length to its content (m21-d, Pro context menu — MIDI:
    /// last note end, audio: remaining source). One store call, no gesture math.
    var onFitToContent: () -> Void = {}
    /// Removes this clip — or the whole arrange selection it belongs to (m23-cf).
    /// The `ClipDeleteCommand` it is handed carries the decision AND the title the
    /// user was shown, so the handler cannot act on a different blast radius from
    /// the one the menu named. Defaulted to a no-op so previews stay one-liners.
    var onDelete: (ClipDeleteCommand) -> Void = { _ in }
    var onSplit: (_ atBeat: Double) -> Void
    var onSetFades: (_ fadeIn: Double, _ fadeOut: Double, _ inCurve: FadeCurve, _ outCurve: FadeCurve) -> Void
    var onSetGain: (_ gainDb: Double) -> Void
    /// Submits the clip's whole gain-envelope point array (m13-e; wired to
    /// `ProjectStore.setClipGainEnvelope`, whole-array replace + canonicalize).
    /// Empty clears the envelope.
    var onSetGainEnvelope: (_ points: [ClipGainPoint]) -> Void = { _ in }
    /// Retargets the clip's timeline length (audio stretch handle, ii-e).
    var onStretch: (_ toLengthBeats: Double) -> Void

    // MARK: Take-group chrome (M5 iii-c)

    /// A "group · N" badge when this clip is a comp member (nil for an ordinary
    /// clip). Marks the block as part of a take group at a glance.
    var takeBadge: String? = nil
    /// True when this member's left edge is an internal comp splice — draw a thin
    /// glowing splice line there (the group's outer start is never a splice).
    var spliceAtStart: Bool = false
    /// The group's lanes, for the member context menu's "Select Take N" entries.
    var takeMenuLanes: [TakeMenuLane] = []
    /// Swaps the comp to a whole-lane take (wired to `selectTake`).
    var onSelectTakeLane: (_ laneID: UUID) -> Void = { _ in }
    /// Dissolves the group into ordinary clips (wired to `flattenTakeGroup`).
    var onFlattenTakeGroup: () -> Void = {}

    // MARK: Quantize & groove (m11-a)

    /// Opens the Quantize panel for this clip (MIDI only — note quantize).
    var onOpenQuantize: () -> Void = {}
    /// Opens the Quantize panel focused on the extract affordance (both kinds —
    /// `groove.extract` supports MIDI onsets and audio transients).
    var onExtractGroove: () -> Void = {}

    // MARK: Convert to voice (m10-p-5)

    /// "Convert to Voice…" (audio clips only, Pro menu — sp-c): opens the
    /// convert sheet, which rides the SAME client/store seams as the wire's
    /// `vc.convertVocals` clipId-form.
    var onConvertToVoice: () -> Void = {}

    // MARK: Crossfade (m11-d)

    /// The id of this clip's eligible crossfade partner — the adjacent-or-
    /// overlapping ordinary AUDIO clip to its right — or nil when there is none
    /// (then the "Crossfade with Next" menu is hidden). Audio + Pro only.
    var crossfadeNextClipID: UUID? = nil
    /// Crossfades this clip with its right neighbour by the given beat length
    /// (wired to `ProjectStore.crossfadeClips`, one undo step).
    var onCrossfadeWithNext: (_ lengthBeats: Double) -> Void = { _ in }

    // MARK: Edit refusal (m17-c)

    /// A refused clip edit's message (the store's LocalizedError VERBATIM — the
    /// same string the wire returns), shown as a transient amber bubble over
    /// this block. nil in normal use; the parent clears it after a few seconds.
    var refusalMessage: String? = nil

    /// A take lane reference for the member context menu.
    struct TakeMenuLane: Identifiable, Equatable { let id: UUID; let name: String }

    /// Captured once at drag start so per-tick math is stable while the block
    /// relocates under the cursor.
    private struct ActiveDrag: Equatable {
        var zone: ClipZone
        var originStart: Double
        var originLength: Double
        var originRatio: Double
        var startLocalX: CGFloat
    }

    @State private var drag: ActiveDrag?
    @State private var readout: String?
    @State private var hovering = false
    @State private var gainDragOrigin: Double?
    /// Live working copy of the gain envelope while a breakpoint is dragged
    /// (m13-e) — non-nil ONLY during a drag, so per-tick moves render from a
    /// stable-order draft (the store canonicalizes for the model). The
    /// `AutomationLaneEditor` draft idiom.
    @State private var envDraft: [ClipGainPoint]?
    /// Live ⌥ state while hovering (drives the stretch-handle grip cue). Tracked
    /// by a flags-changed monitor installed only while the pointer is over the
    /// block, so at most one clip carries a monitor at a time.
    @State private var optionHeld = false
    @State private var flagsMonitor: Any?

    private var ppb: CGFloat { geometry.pixelsPerBeat }
    private var clipOriginX: CGFloat { CGFloat(clip.startBeat) * ppb }
    /// Pro-only (sp-c): the gain dB chip and its drag are a clip-edit affordance.
    private var showGain: Bool { pro && width > 40 && (clip.gainDb != 0 || hovering || isFocused) }

    // MARK: - Gain envelope overlay (m13-e)

    /// The per-clip gain-envelope breakpoint overlay shows on a SELECTED AUDIO
    /// clip in PRO density only (docs/DESIGN-LANGUAGE.md "Panels" — Simple hides
    /// clip-edit chrome). Selecting the clip IS the envelope-edit mode; the
    /// overlay only hit-tests its breakpoint dots, so the clip body's
    /// move/split/trim/select gestures pass through untouched between dots.
    private var showGainEnvelope: Bool { pro && !clip.isMIDI && isFocused }
    /// Points rendered right now: the live drag draft when dragging, else the
    /// canonical model envelope.
    private var envPoints: [ClipGainPoint] { envDraft ?? clip.gainEnvelope }
    /// Named coordinate space so a breakpoint drag reads CLIP-LOCAL points
    /// (0…width, 0…height) regardless of where the block is stacked.
    private var envSpace: String { "clipEnv-\(clip.id.uuidString)" }
    /// Vertical dB window the overlay MAPS across the clip body (louder at top).
    /// A usable riding range, narrower than the model's full -72…24 clamp; a
    /// point beyond it (e.g. an agent-set -72) still stores its true value and
    /// simply pins to the nearest edge when drawn.
    private nonisolated static let envDisplayRange: ClosedRange<Double> = -24...12
    private var playheadWithinClip: Bool {
        playheadBeat >= clip.startBeat && playheadBeat <= clip.startBeat + clip.lengthBeats
    }

    /// Clip-local x for a clip-relative beat.
    private func envX(_ beat: Double) -> CGFloat { CGFloat(beat) * ppb }
    /// Clip-local y for a gain in dB (top = loud), clamped into the body.
    private func envY(_ db: Double) -> CGFloat {
        let lo = Self.envDisplayRange.lowerBound, hi = Self.envDisplayRange.upperBound
        let frac = (hi - db) / (hi - lo)
        return min(max(0, CGFloat(frac) * height), height)
    }
    /// The dB a body y maps to (inverse of `envY`), clamped to the model range.
    private func envDb(forY y: CGFloat) -> Double {
        let lo = Self.envDisplayRange.lowerBound, hi = Self.envDisplayRange.upperBound
        let frac = Double(1 - min(max(0, y / height), 1))
        return (lo + frac * (hi - lo)).clamped(to: Clip.gainDbRange)
    }
    private func envBeat(forX x: CGFloat) -> Double {
        Double(min(max(0, x), width) / ppb).clamped(to: 0...max(0, clip.lengthBeats))
    }

    /// Amber hint: this clip is stretched OUTSIDE the 0.75–1.5× transparent band
    /// (docs/DESIGN-LANGUAGE.md amber = warning; never a hard block).
    private var outOfBand: Bool { ClipStretch.isOutOfBand(ratio: clip.stretchRatio) }
    /// Any amber warning on this block (stretch out-of-band OR a tempo-boundary
    /// crossing) — both use `DAWTheme.record` amber, both are hints not blocks.
    private var amberWarning: Bool { outOfBand || crossesTempoBoundary }
    /// Persistent ratio/pitch badge for a non-identity clip (nil for identity).
    private var badgeText: String? {
        ClipStretch.badge(ratio: clip.stretchRatio, semitones: clip.pitchShiftSemitones)
    }
    /// Border/glow accent: red on render failure, amber out-of-band, else the
    /// clip tint. One accent per meaning (design rule 3).
    private var borderColor: Color {
        if renderVisual == .error { return DAWTheme.clip }
        if amberWarning { return DAWTheme.record }
        return tint
    }
    private var strokeOpacity: Double {
        if isSelected { return 0.95 }
        if amberWarning || renderVisual == .error { return 0.85 }
        return 0.55
    }
    private var strokeWidth: CGFloat {
        (isSelected || amberWarning || renderVisual == .error) ? 1.5 : 1
    }
    private var glowIntensity: Double {
        if renderVisual == .error { return 0.55 }
        if amberWarning { return 0.4 }
        return isSelected ? 0.5 : 0
    }
    /// Tooltip: base edit hint, plus the out-of-band ratio note when amber-tinted.
    private var helpText: String {
        // Simple (sp-c): the block is move-only, so the hint drops the Pro verbs.
        let base: String
        if !pro {
            base = clip.isMIDI
                ? "MIDI clip — click to edit notes, drag to move"
                : "\(clip.name) — drag to move"
        } else {
            base = clip.isMIDI
                ? "MIDI clip — click to edit notes, drag to move, double-click to split"
                : "\(clip.name) — drag to move, edges to trim, corners to fade, ⌥-drag the right edge to time-stretch"
        }
        var hint = base
        if outOfBand { hint += "\n" + ClipStretch.outOfBandHelp(ratio: clip.stretchRatio) }
        if crossesTempoBoundary {
            hint += "\nThis audio crosses a tempo change — it plays at its own speed through it, so beats inside drift. Bounce or re-record to lock it to the new tempo."
        }
        return hint
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(tint.opacity(isSelected ? 0.34 : 0.22))
            .overlay { waveform }
            .overlay { noteMap }
            .overlay { shimmer }
            .overlay { decorations }
            .overlay { gainEnvelopeOverlay }
            .overlay(alignment: .leading) { label }
            .overlay(alignment: .trailing) { stretchGrip }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(borderColor.opacity(strokeOpacity), lineWidth: strokeWidth)
            )
            .overlay(alignment: .topTrailing) { stretchBadge }
            .overlay(alignment: .topLeading) { tempoBoundaryBadge }
            .overlay(alignment: .bottomLeading) { errorDot }
            .overlay(alignment: .bottomTrailing) { gainChip }
            .overlay(alignment: .leading) { spliceLine }
            .overlay(alignment: .bottom) { takeBadgeView }
            .overlay(alignment: .top) { readoutBubble }
            .overlay(alignment: .top) { refusalBubble }
            .glow(borderColor, radius: 5, intensity: glowIntensity)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            // Pointer affordances (docs/DESIGN-LANGUAGE.md): trim edges / fade grips
            // resize, the gain chip drags up/down, the body grabs — mirrors
            // `beginDrag`'s zone routing so the hover cue matches the press.
            .hoverCursor(resolve: clipCursor)
            // Pro-only gesture entry points (sp-c): the ⌥ time-stretch handle, the
            // double-click split, and the ⌥-click fade-curve toggle. In Simple the
            // gesture mask drops them (`.subviews` = this gesture disabled) so they
            // don't recognize — leaving `clipDrag` (which force-moves the body, see
            // `beginDrag`) and the select tap as the only Simple interactions.
            .highPriorityGesture(stretchDrag, including: pro ? .all : .subviews)
            .gesture(clipDrag)
            .simultaneousGesture(doubleClickSplit, including: pro ? .all : .subviews)
            .simultaneousGesture(optionClickFadeToggle, including: pro ? .all : .subviews)
            // m23-g1: a plain click replaces the selection; shift/⌘ toggles this
            // block in or out of it. `TapGesture` carries no event, so the chord
            // is read from the live modifier state at mouse-up — the same
            // `NSEvent.modifierFlags` read `startFlagsMonitor` uses for the ⌥
            // cue (see `ArrangeClickModifiers.current` for what that does and
            // does not prove).
            .onTapGesture { onSelect(.current) }
            .onHover { h in
                hovering = h
                // The ⌥ flags monitor only drives the Pro stretch-grip cue — never
                // install it in Simple (no monitor when there's nothing to cue).
                if h && pro { startFlagsMonitor() } else { stopFlagsMonitor() }
            }
            .onDisappear { stopFlagsMonitor() }
            .contextMenu { contextMenu }
            .help(helpText)
    }

    // MARK: - Stretch affordances (M5 ii-e)

    /// Animated shimmer while the clip's offline stretch render is pending.
    @ViewBuilder
    private var shimmer: some View {
        if renderVisual == .shimmer {
            ClipShimmer(tint: tint)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    /// Persistent SF Mono badge on any non-identity clip, so stretched clips read
    /// distinct at a glance — amber when out-of-band, neutral otherwise.
    @ViewBuilder
    private var stretchBadge: some View {
        if let text = badgeText, width > 30 {
            Text(text)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(outOfBand ? DAWTheme.record : DAWTheme.textPrimary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(DAWTheme.panel.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .glow(DAWTheme.record, radius: 2, intensity: outOfBand ? 0.5 : 0)
                .padding(3)
                .allowsHitTesting(false)
        }
    }

    /// The amber tempo-boundary hint badge (m12-d, design §3.5): a small "△ tempo"
    /// marker on an audio clip that spans a non-trivial tempo change, warning that
    /// its material drifts against the beats past the boundary (never a block —
    /// amber = warning, and the block still plays). MIDI clips never show it.
    @ViewBuilder
    private var tempoBoundaryBadge: some View {
        if crossesTempoBoundary, width > 26 {
            Text("△ tempo")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.record)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(DAWTheme.panel.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .glow(DAWTheme.record, radius: 2, intensity: 0.5)
                .padding(3)
                .allowsHitTesting(false)
        }
    }

    /// The ⌥-stretch grip cue on the right edge of an audio clip — faint on
    /// hover, cyan-lit + glowing while ⌥ is held (drag now stretches, not trims).
    @ViewBuilder
    private var stretchGrip: some View {
        if pro, !clip.isMIDI, width > 24, hovering || optionHeld {
            Text("≈")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(optionHeld ? DAWTheme.playback : DAWTheme.textDim)
                .glow(DAWTheme.playback, radius: 3, intensity: optionHeld ? 0.6 : 0)
                .padding(.trailing, 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Take-group chrome (M5 iii-c)

    /// The group badge on a comp member: "GroupName · N", pinned bottom-center so
    /// a comped clip reads as part of its take group. SF Mono, signal-tinted.
    @ViewBuilder
    private var takeBadgeView: some View {
        if let takeBadge, width > 34 {
            Text(takeBadge)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.signal)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(DAWTheme.panel.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(.bottom, 2)
                .allowsHitTesting(false)
        }
    }

    /// A thin glowing splice line at the member's left edge where the comp cuts
    /// from one take to another (docs/DESIGN-LANGUAGE.md: neon edge = a seam).
    @ViewBuilder
    private var spliceLine: some View {
        if spliceAtStart {
            Rectangle()
                .fill(DAWTheme.signal)
                .frame(width: 1.5)
                .glow(DAWTheme.signal, radius: 3, intensity: 0.7)
                .allowsHitTesting(false)
        }
    }

    /// A small glowing red dot when the offline stretch render failed.
    @ViewBuilder
    private var errorDot: some View {
        if renderVisual == .error {
            Circle()
                .fill(DAWTheme.clip)
                .frame(width: 5, height: 5)
                .glow(DAWTheme.clip, radius: 3, intensity: 0.7)
                .padding(4)
                .allowsHitTesting(false)
                .help("Time-stretch render failed — re-edit the stretch to retry")
        }
    }

    // MARK: - ⌥ tracking (stretch-grip cue)

    private func startFlagsMonitor() {
        optionHeld = NSEvent.modifierFlags.contains(.option)
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            optionHeld = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func stopFlagsMonitor() {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        optionHeld = false
    }

    // MARK: - Drawing

    /// Opacity the audio waveform DIMS to while the gain-envelope overlay is up
    /// (m13-g sub-task 3): the cyan polyline is the primary layer, but the
    /// waveform stays visible as a ghost UNDER it so breakpoints can be placed
    /// against the audio (docs/DESIGN-LANGUAGE.md "Clip editing" — overlay cyan,
    /// waveform ghosted). Full strength when no overlay is showing.
    private static let envGhostOpacity: Double = 0.4

    @ViewBuilder
    private var waveform: some View {
        if let peaks = waveformPeaks {
            ClipWaveform(
                peaks: peaks,
                startOffsetSeconds: clip.startOffsetSeconds,
                secondsPerBeat: secondsPerBeat,
                pixelsPerBeat: ppb,
                tint: tint
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // Ghost the waveform under the envelope overlay so it reads as a
            // backdrop the breakpoints ride, not a competing layer (m13-g).
            .opacity(showGainEnvelope ? Self.envGhostOpacity : 1)
        } else if !clip.isMIDI {
            // Audio honesty (beta m10-f): while the peaks load off-main (or the file
            // is unreadable → computePeaks nil), show a dim flat center line so an
            // audio clip never reads as blank. Minimal on purpose — no shimmer (that
            // idiom means "stretch working"), no redesign.
            Rectangle()
                .fill(tint.opacity(0.3))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
                .opacity(showGainEnvelope ? Self.envGhostOpacity : 1)
                .allowsHitTesting(false)
        }
    }

    /// Mini note map for a MIDI clip (beta m10-f): pitch-mapped tint pills so a
    /// MIDI clip shows its content, the sibling of the audio waveform. Sits in the
    /// same overlay slot (under decorations), value-in only, redraws on data change.
    @ViewBuilder
    private var noteMap: some View {
        if clip.isMIDI, let notes = clip.notes, !notes.isEmpty {
            ClipMIDIMap(
                notes: notes,
                lengthBeats: clip.lengthBeats,
                pixelsPerBeat: ppb,
                tint: tint,
                controllerLanes: clip.controllerLanes
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder
    private var label: some View {
        if width > 34 {
            HStack(spacing: 4) {
                Image(systemName: clip.isMIDI ? "pianokeys" : "waveform")
                    .font(.system(size: 8))
                Text(clip.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
        }
    }

    /// Translucent fade shading (over the waveform) + the top-corner fade grips.
    /// Pro-only (sp-c): fades are a clip-edit affordance, so Simple draws no fade
    /// chrome at all (no grips, no shading) — the block reads as a plain clip.
    @ViewBuilder
    private var decorations: some View {
        if pro {
            // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
            // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
            let gripBright = (hovering || isSelected) ? 0.9 : 0.4
            let fadeInBeats = clip.fadeInBeats
            let fadeOutBeats = clip.fadeOutBeats
            let fadeInCurve = clip.fadeInCurve
            let fadeOutCurve = clip.fadeOutCurve
            let tint = tint
            let ppb = ppb
            let geometry = geometry
            Canvas { @Sendable context, size in
                if fadeInBeats > 0 {
                    context.fill(Self.fadeInPath(width: size.width, height: size.height,
                                                 fadeInBeats: fadeInBeats, ppb: ppb, curve: fadeInCurve),
                                 with: .color(DAWTheme.background.opacity(0.5)))
                }
                if fadeOutBeats > 0 {
                    context.fill(Self.fadeOutPath(width: size.width, height: size.height,
                                                  fadeOutBeats: fadeOutBeats, ppb: ppb, curve: fadeOutCurve),
                                 with: .color(DAWTheme.background.opacity(0.5)))
                }
                // Grips at each fade's inner end (at the corner when the fade is 0).
                let fiX = geometry.fadeInHandleX(fadeInBeats: fadeInBeats, clipWidth: size.width)
                let foX = geometry.fadeOutHandleX(fadeOutBeats: fadeOutBeats, clipWidth: size.width)
                context.fill(Self.gripTriangle(atX: fiX), with: .color(tint.opacity(gripBright)))
                context.fill(Self.gripTriangle(atX: foX), with: .color(tint.opacity(gripBright)))
            }
            .allowsHitTesting(false)
        }
    }

    /// Rising fade factor 0→1 for progress `t` (linear = t, equal-power = sine).
    private nonisolated static func fadeShape(_ t: Double, _ curve: FadeCurve) -> Double {
        let p = t.clamped(to: 0...1)
        return curve == .linear ? p : sin(p * .pi / 2)
    }

    /// Dimmed region above the rising fade-in curve (top-left) — straight for
    /// linear, bowed for equal-power.
    private nonisolated static func fadeInPath(width w: CGFloat, height h: CGFloat,
                                   fadeInBeats: Double, ppb: CGFloat, curve: FadeCurve) -> Path {
        let fadeW = min(CGFloat(fadeInBeats) * ppb, w)
        guard fadeW > 0 else { return Path() }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: fadeW, y: 0))
        let steps = 14
        for i in 0...steps {
            let xi = fadeW * CGFloat(steps - i) / CGFloat(steps)
            let g = fadeShape(fadeW > 0 ? Double(xi / fadeW) : 0, curve)
            p.addLine(to: CGPoint(x: xi, y: h * (1 - CGFloat(g))))
        }
        p.closeSubpath()
        return p
    }

    /// Dimmed region above the falling fade-out curve (top-right).
    private nonisolated static func fadeOutPath(width w: CGFloat, height h: CGFloat,
                                    fadeOutBeats: Double, ppb: CGFloat, curve: FadeCurve) -> Path {
        let fadeW = min(CGFloat(fadeOutBeats) * ppb, w)
        guard fadeW > 0 else { return Path() }
        let startX = w - fadeW
        var p = Path()
        p.move(to: CGPoint(x: startX, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h))
        let steps = 14
        for i in 0...steps {
            let u = Double(steps - i) / Double(steps)   // 1 → 0 across the fade
            let xi = startX + fadeW * CGFloat(u)
            let g = fadeShape(1 - u, curve)
            p.addLine(to: CGPoint(x: xi, y: h * (1 - CGFloat(g))))
        }
        p.closeSubpath()
        return p
    }

    private nonisolated static func gripTriangle(atX x: CGFloat) -> Path {
        let s: CGFloat = 4.5
        var p = Path()
        p.move(to: CGPoint(x: x - s, y: 0))
        p.addLine(to: CGPoint(x: x + s, y: 0))
        p.addLine(to: CGPoint(x: x, y: s * 1.5))
        p.closeSubpath()
        return p
    }

    // MARK: - Gain readout

    @ViewBuilder
    private var gainChip: some View {
        if showGain {
            Text(ClipEdit.gainDbString(clip.gainDb))
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(DAWTheme.panel.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .glow(DAWTheme.playback, radius: 2, intensity: clip.gainDb != 0 ? 0.35 : 0)
                .padding(3)
                // Cursor for the gain chip is handled by the clip-level resolver's
                // bottom-right region (`clipCursor`) so its tracking area doesn't
                // overlap/race the block's — see `hoverCursor(resolve:)` above.
                .highPriorityGesture(gainDrag)
                .help("Clip gain — drag up/down to adjust")
        }
    }

    private var gainDrag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                DragCursor.set(.resizeUpDown)
                if gainDragOrigin == nil { gainDragOrigin = clip.gainDb }
                let deltaDb = -Double(value.translation.height) * 0.15
                onSetGain(ClipEdit.adjustedGainDb(gainDragOrigin ?? clip.gainDb, deltaDb: deltaDb))
            }
            .onEnded { _ in gainDragOrigin = nil; DragCursor.clear() }
    }

    // MARK: - Gain envelope overlay (m13-e)

    /// A cyan breakpoint line over the clip body — the automation-editor idiom
    /// (`AutomationLaneEditor`), scoped to one audio clip. The polyline draws in
    /// a hit-disabled Canvas; only the small breakpoint dots capture gestures, so
    /// clip move/split/select still work in the empty space between them. Add a
    /// point / clear the envelope from the context menu (conflict-free with the
    /// body's own drag gestures). Cyan = active accent (never violet — not AI).
    @ViewBuilder
    private var gainEnvelopeOverlay: some View {
        if showGainEnvelope {
            // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
            // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
            let envPoints = envPoints
            let ppb = ppb
            let height = height
            ZStack(alignment: .topLeading) {
                Canvas { @Sendable context, size in
                    Self.drawGainEnvelope(&context, size: size, points: envPoints, ppb: ppb, height: height)
                }
                .allowsHitTesting(false)
                ForEach(Array(envPoints.enumerated()), id: \.offset) { index, point in
                    envDotView
                        .position(x: envX(point.beat), y: envY(point.gainDb))
                        .highPriorityGesture(envDotDrag(index))
                        .simultaneousGesture(envDotDelete(index))
                        .help("Gain breakpoint — drag to move, double-click to delete")
                }
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: envSpace)
            // One card summarizes the overlay's add/move/delete affordances (the
            // honest-scope rule for Canvas/gesture chrome). Pro-only by construction.
            .explainable(.clipGainEnvelope)
        }
    }

    /// A single glowing breakpoint dot: a small cyan core inside a 14pt hit area.
    private var envDotView: some View {
        Circle()
            .fill(DAWTheme.playback)
            .frame(width: 7, height: 7)
            .glow(DAWTheme.playback, radius: 3, intensity: 0.6)
            .frame(width: 14, height: 14)          // generous hit target
            .contentShape(Circle())
    }

    /// Draws the faint 0 dB guide and the neon envelope polyline (flat lead-in /
    /// lead-out, mirroring `Clip.envelopeGain`'s constant extension). Empty →
    /// just the guide, inviting the first point.
    private nonisolated static func drawGainEnvelope(_ context: inout GraphicsContext, size: CGSize,
                                         points: [ClipGainPoint], ppb: CGFloat, height: CGFloat) {
        // Clip-local x/y mapping (the instance `envX`/`envY`, reproduced from the
        // captured value inputs so the renderer stays `self`-free).
        func envX(_ beat: Double) -> CGFloat { CGFloat(beat) * ppb }
        func envY(_ db: Double) -> CGFloat {
            let lo = envDisplayRange.lowerBound, hi = envDisplayRange.upperBound
            let frac = (hi - db) / (hi - lo)
            return min(max(0, CGFloat(frac) * height), height)
        }
        // Faint dashed guide at 0 dB (unity) — the resting level.
        let zeroY = envY(0)
        context.stroke(
            Path { $0.move(to: CGPoint(x: 0, y: zeroY)); $0.addLine(to: CGPoint(x: size.width, y: zeroY)) },
            with: .color(DAWTheme.textDim.opacity(0.22)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        guard let first = points.first, let last = points.last else { return }
        var line = Path()
        let firstY = envY(first.gainDb)
        line.move(to: CGPoint(x: 0, y: firstY))
        line.addLine(to: CGPoint(x: envX(first.beat), y: firstY))
        for point in points.dropFirst() {
            line.addLine(to: CGPoint(x: envX(point.beat), y: envY(point.gainDb)))
        }
        line.addLine(to: CGPoint(x: size.width, y: envY(last.gainDb)))
        // Bloom-under-core glow recipe (the automation polyline).
        context.stroke(line, with: .color(DAWTheme.playback.opacity(0.18)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: .color(DAWTheme.playback.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }

    /// Drag a breakpoint (coalesced under the store's `clip.gainEnv:<clipId>` key
    /// → one undo step). Reads clip-local coordinates via the named space.
    private func envDotDrag(_ index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(envSpace))
            .onChanged { value in
                if envDraft == nil { envDraft = clip.gainEnvelope }
                guard var pts = envDraft, pts.indices.contains(index) else { return }
                let beat = envBeat(forX: value.location.x)
                let db = envDb(forY: value.location.y)
                pts[index] = ClipGainPoint(beat: beat, gainDb: db)
                envDraft = pts
                onSetGainEnvelope(pts)
                readout = "\(fmt(beat)) · \(ClipEdit.gainDbString(db))"
            }
            .onEnded { _ in envDraft = nil; readout = nil }
    }

    /// Double-click a breakpoint to delete it.
    private func envDotDelete(_ index: Int) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                var pts = clip.gainEnvelope
                guard pts.indices.contains(index) else { return }
                pts.remove(at: index)
                onSetGainEnvelope(pts)
            }
    }

    /// Adds a breakpoint at the playhead's clip-relative beat, pinned to the
    /// envelope's current value there (0 dB when empty) so it lands ON the curve.
    private func addGainPointAtPlayhead() {
        let rel = playheadBeat - clip.startBeat
        guard rel >= 0, rel <= clip.lengthBeats else { return }
        let db = clip.gainEnvelope.isEmpty
            ? 0
            : Clip.envelopeDb(points: clip.gainEnvelope, atBeat: rel)
        onSetGainEnvelope(clip.gainEnvelope + [ClipGainPoint(beat: rel, gainDb: db)])
    }

    // MARK: - Cursor readout

    @ViewBuilder
    private var readoutBubble: some View {
        if let readout {
            Text(readout)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.hairline, lineWidth: 1))
                .glow(DAWTheme.playback, radius: 3, intensity: 0.3)
                .fixedSize()
                .offset(y: -20)
                .allowsHitTesting(false)
        }
    }

    /// The clip-anchored edit-refusal bubble (m17-c): the shared
    /// `ArrangeRefusalBubble`, hung above this block. The empty-lane create's
    /// refusal (m23-e) uses the SAME component on the lane — one chip design,
    /// two anchors.
    @ViewBuilder
    private var refusalBubble: some View {
        if let refusalMessage {
            ArrangeRefusalBubble(message: refusalMessage)
                .offset(y: -30)
        }
    }

    // MARK: - Gestures

    /// Rest cursor over the clip block (docs/DESIGN-LANGUAGE.md "Pointer
    /// affordances"). Simple: the whole body MOVES → grab (no trim/fade zones).
    /// Pro: mirror `beginDrag`'s zone routing — trim edges and fade grips resize,
    /// the gain chip (bottom-right value control) drags up/down, the body grabs.
    private func clipCursor(at p: CGPoint) -> CursorKind? {
        guard pro else { return .grab }
        if showGain, p.x >= width - 34, p.y >= height - 16 { return .resizeUpDown }
        let zone = geometry.classifyZone(
            localPoint: p, clipWidth: width,
            fadeInBeats: clip.fadeInBeats, fadeOutBeats: clip.fadeOutBeats)
        return CursorAffordance.forClipZone(zone)
    }

    private var clipDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineLanesView.contentSpace))
            .onChanged { value in
                let active = drag ?? beginDrag(at: value.startLocation)
                // Hold the zone's drag cursor even if the pointer leaves the block
                // (a body closes the hand; an edge/fade keeps its resize).
                DragCursor.set(CursorAffordance.forClipZone(active.zone, dragging: true))
                applyDrag(active, translationBeats: Double(value.translation.width / ppb))
            }
            .onEnded { _ in drag = nil; readout = nil; DragCursor.clear() }
    }

    private func beginDrag(at start: CGPoint) -> ActiveDrag {
        let localX = start.x - clipOriginX
        let localY = start.y - laneOriginY
        // Simple (sp-c): collapse every zone to `.body` so an edge/corner press
        // MOVES the clip instead of trimming/fading — no dead hit-zone under the
        // now-hidden trim strips and fade grips.
        let zone: ClipZone = pro
            ? geometry.classifyZone(
                localPoint: CGPoint(x: localX, y: localY), clipWidth: width,
                fadeInBeats: clip.fadeInBeats, fadeOutBeats: clip.fadeOutBeats)
            : .body
        let active = ActiveDrag(zone: zone, originStart: clip.startBeat,
                                originLength: clip.lengthBeats, originRatio: clip.stretchRatio,
                                startLocalX: localX)
        drag = active
        return active
    }

    /// ⌥-drag the right edge of an AUDIO clip to time-stretch instead of trim
    /// (M5 ii-e). Higher priority than `clipDrag`, but only recognized while ⌥ is
    /// held, so a plain drag still trims/moves. On the trailing edge it retargets
    /// the length via `onStretch` (→ `ProjectStore.stretchClip`, window-invariant)
    /// with a live "length · ratio" readout that mirrors the store's clamp/
    /// re-derivation; ⌥-drag anywhere else (or on a MIDI clip) falls back to the
    /// normal drag so ⌥ is special ONLY for the audio stretch handle.
    private var stretchDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineLanesView.contentSpace))
            .modifiers(.option)
            .onChanged { value in
                let active = drag ?? beginDrag(at: value.startLocation)
                let dxBeats = Double(value.translation.width / ppb)
                if ClipStretch.isStretchDrag(zone: active.zone, optionHeld: true, isAudio: !clip.isMIDI) {
                    // ⌥-stretch retargets the right edge — a horizontal resize.
                    DragCursor.set(.resizeLeftRight)
                    let target = ClipStretch.targetLength(
                        originalStart: active.originStart, originalLength: active.originLength,
                        dragDeltaBeats: dxBeats, snap: snap, meterMap: meterMap)
                    let preview = ClipStretch.stretchPreview(
                        oldLength: active.originLength, oldRatio: active.originRatio, targetLength: target)
                    onStretch(target)
                    readout = ClipStretch.stretchReadout(length: preview.length, ratio: preview.ratio)
                } else {
                    DragCursor.set(CursorAffordance.forClipZone(active.zone, dragging: true))
                    applyDrag(active, translationBeats: dxBeats)
                }
            }
            .onEnded { _ in drag = nil; readout = nil; DragCursor.clear() }
    }

    private func applyDrag(_ active: ActiveDrag, translationBeats dxBeats: Double) {
        switch active.zone {
        case .body:
            // m23-g2: the gesture hands over its RAW translation and its own
            // drag-origin start; `AppModel.dragArrangeClips` snaps the ANCHOR
            // once and translates the whole selection rigidly. The block does
            // NOT snap here — a per-clip snap is what welds a group together
            // (`ArrangeGroupDrag`), and having the block compute a target the
            // store might clamp would give the app two producers of the same
            // number.
            //
            // The readout shows the ACHIEVED start, not the requested one. In
            // the beat-0 clamp case — the exact case this item is about — they
            // differ, and a bubble reading "start 0.0" while the clip sits at
            // 2.0 would be the honesty violation the design language forbids.
            readout = "start " + fmt(onMove(active.originStart, dxBeats))
        case .trimStart:
            let (s, l) = ClipEdit.trimStart(
                originalStart: active.originStart, originalLength: active.originLength,
                newStartBeatRaw: active.originStart + dxBeats, snap: snap, meterMap: meterMap)
            onTrim(s, l)
            readout = "start " + fmt(s) + "  len " + fmt(l)
        case .trimEnd:
            let (s, l) = ClipEdit.trimEnd(
                originalStart: active.originStart,
                newEndBeatRaw: active.originStart + active.originLength + dxBeats,
                snap: snap, meterMap: meterMap)
            onTrim(s, l)
            readout = "len " + fmt(l)
        case .fadeInHandle:
            let localX = active.startLocalX + CGFloat(dxBeats) * ppb
            let fadeIn = ClipEdit.fadeInBeats(
                forLocalX: localX, length: clip.lengthBeats,
                fadeOutBeats: clip.fadeOutBeats, pixelsPerBeat: ppb)
            onSetFades(fadeIn, clip.fadeOutBeats, clip.fadeInCurve, clip.fadeOutCurve)
            readout = "fade in " + fmt(fadeIn)
        case .fadeOutHandle:
            let localX = active.startLocalX + CGFloat(dxBeats) * ppb
            let fadeOut = ClipEdit.fadeOutBeats(
                forLocalX: localX, clipWidth: width, length: clip.lengthBeats,
                fadeInBeats: clip.fadeInBeats, pixelsPerBeat: ppb)
            onSetFades(clip.fadeInBeats, fadeOut, clip.fadeInCurve, clip.fadeOutCurve)
            readout = "fade out " + fmt(fadeOut)
        }
    }

    /// Double-click at a position splits the clip there (snapped when it fits).
    private var doubleClickSplit: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .named(TimelineLanesView.contentSpace))
            .onEnded { value in
                let rel = geometry.beat(forX: value.location.x - clipOriginX)
                if let beat = ClipEdit.snappedSplit(
                    timelineBeatRaw: clip.startBeat + rel, clipStart: clip.startBeat,
                    clipLength: clip.lengthBeats, snap: snap, meterMap: meterMap) {
                    onSplit(beat)
                }
            }
    }

    /// Alt/option-click a fade grip flips its curve (linear ↔ equal-power).
    private var optionClickFadeToggle: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .named(TimelineLanesView.contentSpace))
            .modifiers(.option)
            .onEnded { value in
                let zone = geometry.classifyZone(
                    localPoint: CGPoint(x: value.location.x - clipOriginX,
                                        y: value.location.y - laneOriginY),
                    clipWidth: width, fadeInBeats: clip.fadeInBeats, fadeOutBeats: clip.fadeOutBeats)
                switch zone {
                case .fadeInHandle:
                    onSetFades(clip.fadeInBeats, clip.fadeOutBeats,
                               ClipEdit.toggledCurve(clip.fadeInCurve), clip.fadeOutCurve)
                case .fadeOutHandle:
                    onSetFades(clip.fadeInBeats, clip.fadeOutBeats,
                               clip.fadeInCurve, ClipEdit.toggledCurve(clip.fadeOutCurve))
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var contextMenu: some View {
        // ═══ DELETE, FIRST AND IN BOTH DENSITIES (m23-cf) ═══
        //
        // ⚠️ DELIBERATELY OUTSIDE THE `if pro` BLOCK BELOW, and that placement is
        // the whole user-facing point of the item. Every other entry here is
        // clip-EDIT chrome and Pro-only (sp-c), which means a non-take clip in
        // SIMPLE density produced an EMPTY BUILDER — i.e. no context menu at all.
        // So a beginner, in the density built for beginners, had no route to
        // removing a clip except the bare DELETE key. A user hit exactly that and
        // reported "I cannot remove them". Removing a clip is not an expert edit;
        // it is the other half of creating one.
        //
        // FIRST rather than last because a destructive entry buried under nine
        // fade/quantize/crossfade items is not discoverable, and in Simple it is
        // the only entry there is.
        Button(deleteCommand.title, role: .destructive) { onDelete(deleteCommand) }
        // The separator is CONDITIONAL because in SIMPLE density on a NON-TAKE
        // clip both blocks below are empty, so an unconditional one would be a
        // trailing rule with nothing under it — in the beginner density, on the
        // beginner's first context menu.
        //
        // ⚠️ MEASURED, AND THE MEASUREMENT SAYS THE GUARD IS NOT LOAD-BEARING
        // HERE. A/B on staging (m23-cf, macOS 26 / Darwin 25.4), menu window
        // heights read off the window list at layer 101:
        //   • conditional (this code), Simple non-take ....... 99 × 34
        //   • UNCONDITIONAL `Divider()`, same state .......... 99 × 34   ← collapsed
        //   • calibration `Button + Divider + Button` ........ 165 × 69
        // The 34 → 69 step (one item ≈ 23 pt + one separator ≈ 12 pt) proves the
        // probe SEES separators, so the first two reading the same is a real
        // negative: SwiftUI drops a trailing `Divider()` in menu content.
        // The guard stays anyway — it states the intent in the source instead of
        // leaning on undocumented AppKit behaviour, and it costs one Bool. Do not
        // "simplify" it away on the strength of the measurement alone; the
        // measurement is one OS version wide.
        //
        // A keyboard-driven check could not have decided this either way: a
        // separator is unselectable, so Down still lands on Delete.
        if pro || !takeMenuLanes.isEmpty { Divider() }
        // Take-group members: comp is edited via the take lanes, so the member's
        // menu offers take swaps + the flatten escape hatch instead of clip edits.
        // These stay in BOTH modes — take lanes are density-unaffected (sp-c).
        if !takeMenuLanes.isEmpty {
            ForEach(takeMenuLanes) { lane in
                Button("Select \(lane.name)") { onSelectTakeLane(lane.id) }
            }
            Divider()
            Button("Flatten Group") { onFlattenTakeGroup() }
            if pro { Divider() }
        }
        // Clip-edit entries are Pro-only (sp-c): split / gain / fade curves. In
        // Simple a non-take clip now shows the Delete entry above and nothing
        // else — before m23-cf this builder was EMPTY there, so SwiftUI produced
        // no menu at all.
        if pro {
            Button("Split at Playhead") {
                if let beat = ClipEdit.snappedSplit(
                    timelineBeatRaw: playheadBeat, clipStart: clip.startBeat,
                    clipLength: clip.lengthBeats, snap: snap, meterMap: meterMap) {
                    onSplit(beat)
                }
            }
            // Fit to Content (m21-d): one gesture to make the clip exactly as
            // long as its material — MIDI ends at the last note, audio at the
            // end of its source recording. Both kinds, Pro-only (sp-c).
            Button("Fit to Content") { onFitToContent() }
            Button("Reset Gain") { onSetGain(0) }
                .disabled(clip.gainDb == 0)
            // Gain envelope (m13-e): audio clips only — the breakpoint line rides
            // the clip's level over time. Add lands a point on the curve at the
            // playhead; drag the dots to shape it; Clear removes the whole line.
            if !clip.isMIDI {
                Button("Add Gain Point at Playhead") { addGainPointAtPlayhead() }
                    .disabled(!playheadWithinClip)
                Button("Clear Gain Envelope") { onSetGainEnvelope([]) }
                    .disabled(clip.gainEnvelope.isEmpty)
            }
            Divider()
            Button(clip.fadeInCurve == .linear ? "Fade In: Equal Power" : "Fade In: Linear") {
                onSetFades(clip.fadeInBeats, clip.fadeOutBeats,
                           ClipEdit.toggledCurve(clip.fadeInCurve), clip.fadeOutCurve)
            }
            Button(clip.fadeOutCurve == .linear ? "Fade Out: Equal Power" : "Fade Out: Linear") {
                onSetFades(clip.fadeInBeats, clip.fadeOutBeats,
                           clip.fadeInCurve, ClipEdit.toggledCurve(clip.fadeOutCurve))
            }
            // Crossfade (m11-d): only on an AUDIO clip that has an adjacent or
            // overlapping ordinary audio clip to its right. A small inline length
            // choice — the overlap must be sanctioned by this tool, never left
            // silent (moveClip trims any accidental overlap). Pro-only (sp-c).
            if !clip.isMIDI, crossfadeNextClipID != nil {
                Divider()
                Menu("Crossfade with Next") {
                    Button("¼ Beat") { onCrossfadeWithNext(0.25) }
                    Button("½ Beat") { onCrossfadeWithNext(0.5) }
                    Button("1 Beat") { onCrossfadeWithNext(1) }
                    Button("2 Beats") { onCrossfadeWithNext(2) }
                }
            }
            // Quantize & groove (m11-a): clip-edit entries stay Pro-only (sp-c). A
            // MIDI clip can be note-quantized; both kinds can have a groove extracted.
            Divider()
            if clip.isMIDI {
                Button("Quantize…") { onOpenQuantize() }
            }
            Button("Extract Groove…") { onExtractGroove() }
            // Convert to voice (m10-p-5): AUDIO clips only — a MIDI clip has no
            // recording to convert (the store's voiceConversionSource law), so
            // the item simply doesn't exist there (hidden, never
            // offered-then-errored). Pro-only like every clip-menu entry (sp-c).
            if !clip.isMIDI {
                Divider()
                Button("Convert to Voice…") { onConvertToVoice() }
            }
        }
    }

    /// What this block's Delete entry says and targets (m23-cf). ONE producer for
    /// both — the label and the id list must never disagree, so the menu reads
    /// `.title` and the action passes the SAME value back to `onDelete`.
    private var deleteCommand: ClipDeleteCommand {
        DeleteMenuPolicy.clipContextCommand(clickedClipIsSelected: isSelected,
                                            arrangeSelectionCount: arrangeSelectionCount)
    }

    /// Compact beat readout for the drag bubble (2 decimals, trailing zeros trimmed).
    private func fmt(_ beats: Double) -> String {
        String(format: "%.2f", beats)
    }
}

/// The crossfade "bowtie" marker (m11-d): two crossing strokes over the overlap
/// of two audio clips, echoing one fading out as the other fades in. Neutral
/// green (the audio signal tint) — a crossfade is not AI, so no violet (Rule 3).
/// Carries the `.crossfade` Explain anchor via the parent; the tooltip names it.
private struct CrossfadeSeamBadge: View {
    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        Canvas { @Sendable context, size in
            let w = size.width, h = size.height
            var x = Path()
            x.move(to: CGPoint(x: 0, y: h)); x.addLine(to: CGPoint(x: w, y: 0))
            x.move(to: CGPoint(x: 0, y: 0)); x.addLine(to: CGPoint(x: w, y: h))
            context.stroke(x, with: .color(DAWTheme.signal.opacity(0.85)), lineWidth: 1.5)
        }
        .glow(DAWTheme.signal, radius: 3, intensity: 0.35)
        .help("Crossfade — one clip fades out as the next fades in")
    }
}

/// A soft diagonal highlight sweeping left→right over a clip whose offline
/// stretch render is pending (M5 ii-e). The "working" cue from the design
/// language — a subtle animated gradient, never a spinner (docs/DESIGN-LANGUAGE.md
/// Clip editing). Self-animating on a slow loop via `onAppear`; the parent
/// removes it the instant the render lands, so it costs nothing at rest. The
/// highlight carries the clip tint (green audio / cyan MIDI / violet AI) so a
/// shimmering clip still reads as itself.
private struct ClipShimmer: View {
    var tint: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(28, w * 0.4)
            LinearGradient(
                colors: [.clear, tint.opacity(0.30), Color.white.opacity(0.22),
                         tint.opacity(0.30), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + phase * (w + band))
                .blendMode(.screen)
                .onAppear {
                    withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .allowsHitTesting(false)
    }
}
