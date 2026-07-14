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

/// Reports the `.lanes` horizontal scroll offset up to the pinned `.ruler` so the
/// two stay in sync (m13-g). The lane content's `minX` in the scroll coordinate
/// space, negated, is the scroll distance.
struct ArrangeHOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Arrange timeline: one horizontal lane per track (same order as the sidebar),
/// clips as rounded interactive blocks positioned by beats, a beat/bar grid, and
/// a glowing cyan playhead. Clips move/trim/split/fade under the snap grid and
/// audio clips draw a peak waveform (M5 i-d); a MIDI clip tap still opens the
/// piano roll (docs/DESIGN-LANGUAGE.md "Glass Cockpit"). A track whose automation
/// disclosure is open grows a breakpoint-editor row under its clip lane,
/// beat-aligned with the grid. No zoom yet.
struct TimelineLanesView: View {
    var tracks: [Track]
    var positionBeats: Double
    var selectedClipID: UUID?
    var onSelectClip: (Clip) -> Void
    /// Tracks whose automation lane is expanded (shared with the sidebar via
    /// AppModel, so both columns grow the same row and stay aligned).
    var expandedTrackIDs: Set<UUID> = []
    /// Which lane each track is editing (trackID → laneID); absent = its first.
    var selectedLaneByTrack: [UUID: UUID] = [:]
    /// Submits an edited breakpoint array (wired to `setAutomationPoints`).
    var onCommitPoints: (_ trackID: UUID, _ laneID: UUID, _ points: [AutomationPoint]) -> Void = { _, _, _ in }

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
    /// The shared-scroll viewport height (m10-j), threaded from ContentView's
    /// GeometryReader. The timeline fills it when the content is SHORT (so the glass
    /// panel doesn't shrink to its content and the column stays flush with the
    /// sidebar) and reports its natural `contentHeight` when TALL, letting the outer
    /// vertical ScrollView own the overflow. 0 (previews / headless callers, and the
    /// legacy non-shared-scroll path) falls back to the natural content height.
    var availableHeight: CGFloat = 0
    /// Clip edits — each wired to one of the five `ProjectStore` clip methods.
    var onMoveClip: (_ trackID: UUID, _ clip: Clip, _ toStartBeat: Double) -> Void = { _, _, _ in }
    var onTrimClip: (_ trackID: UUID, _ clip: Clip, _ newStart: Double, _ newLength: Double) -> Void = { _, _, _, _ in }
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

    // MARK: Audio import drag-drop (beta m10-k)

    /// Imports dropped audio file URLs (wired to `AppModel.importAudioFiles`, which
    /// runs the shared `AudioImportPlan` pipeline). `targetTrackID` is the lane under
    /// the pointer (its kind + the file count decide routing in the plan); `atBeatRaw`
    /// is the unsnapped drop-x beat (the plan snaps it with the effective grid).
    var onImportAudio: (_ urls: [URL], _ targetTrackID: UUID?, _ atBeatRaw: Double) -> Void = { _, _, _ in }

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
    /// `rowHeight` so trim/fade/gain hit-testing tracks the adjustable lane height.
    private var clipGeometry: ClipEditGeometry {
        ClipEditGeometry(pixelsPerBeat: Self.pixelsPerBeat, laneHeight: rowHeight)
    }

    // Fixed scale + row metrics tuned to line up with the sidebar track rows
    // (TrackListView: 42 pt header, 6 pt gaps). The clip-lane height is the DEFAULT
    // for the adjustable `rowHeight` input (beta m10-d) — the sidebar rows read the
    // same store value, so both columns scale in lockstep.
    static let pixelsPerBeat: CGFloat = 16
    /// Ruler height (m11-c grew it 42 → 56 for the marker lane; m12-d grows it
    /// 56 → 80 to seat the TEMPO LANE below the marker lane — each ruler surface
    /// gets its own strip, so no hit zone is overloaded). Top→bottom the 80 pt
    /// ruler stacks: loop band `y ∈ [2, 14]`, marker lane `y ∈ [15, 33]`, tempo
    /// lane `y ∈ [35, 57]` (meter flags in its top row, bpm in its bottom row),
    /// bar numbers `y ≈ 62…71`, baseline at `y = 79`.
    static let rulerHeight: CGFloat = 80
    static let laneHeight: CGFloat = 34
    static let laneSpacing: CGFloat = 6
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
        TakeLaneGeometry(pixelsPerBeat: Self.pixelsPerBeat, rowHeight: Self.takeLaneRowHeight)
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
        return max(bars * basePerBar, 32)   // always show a few empty bars
    }

    private var contentWidth: CGFloat { CGFloat(totalBeats) * Self.pixelsPerBeat }

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
                loopBand
                clipBlocks
                crossfadeSeams
                takeLanes
                automationLanes
                dropAffordance
                playhead
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
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                grid
                clipBlocks
                crossfadeSeams
                takeLanes
                automationLanes
                dropAffordance
                playhead
            }
            .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
            .coordinateSpace(name: Self.contentSpace)
            // Report the live horizontal scroll offset (content minX in the scroll
            // space, negated) so the pinned ruler mirrors it — the m10-j shared-
            // scroll discipline on the horizontal axis (no second vertical scroll,
            // so the columns can't desync; only the ruler tracks this offset).
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: ArrangeHOffsetKey.self,
                    value: -geo.frame(in: .named(Self.hScrollSpace)).minX)
            })
            .onDrop(of: [.fileURL], delegate: laneDropDelegate)
        }
        .coordinateSpace(name: Self.hScrollSpace)
        .onPreferenceChange(ArrangeHOffsetKey.self) { onHScrollChange?($0) }
        .frame(height: laneHeight, alignment: .topLeading)
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
        AudioLaneDropDelegate(
            hover: $dropHover,
            resolve: { point, fileCount in resolveDropHover(at: point, fileCount: fileCount) },
            onImport: onImportAudio)
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
        // Per-beat classification — the SAME meter math as the legacy in-closure loop,
        // run once here so `meterMap` never crosses into the renderer.
        let beatCells: [GridBeatCell] = (0...totalBeats).map { beat in
            let position = meterMap.barBeat(atBeat: Double(beat))
            let isBar = position.beatInBar < 0.001
            return GridBeatCell(
                x: CGFloat(beat) * Self.pixelsPerBeat,
                isBar: isBar,
                barLabel: isBar ? "\(position.bar + 1)" : nil)
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
                } else {
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
                let width = max(3, CGFloat(clip.lengthBeats) * Self.pixelsPerBeat)
                let takeGroup = TakeLaneSelection.group(forMember: clip, in: track)
                ClipBlock(
                    clip: clip,
                    trackID: track.id,
                    tint: tint(clip),
                    isSelected: clip.id == selectedClipID,
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
                    onSelect: { onSelectClip(clip) },
                    onMove: { onMoveClip(track.id, clip, $0) },
                    onTrim: { onTrimClip(track.id, clip, $0, $1) },
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
                    crossfadeNextClipID: isPro ? crossfadeNeighbor(for: clip, in: track) : nil,
                    onCrossfadeWithNext: { length in
                        if let other = crossfadeNeighbor(for: clip, in: track) {
                            onCrossfadeClips(track.id, clip.id, other, length)
                        }
                    }
                )
                .offset(x: CGFloat(clip.startBeat) * Self.pixelsPerBeat, y: laneTop(index))
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
                    .position(x: CGFloat(seam.centerBeat) * Self.pixelsPerBeat,
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
                    pixelsPerBeat: Self.pixelsPerBeat,
                    laneHeight: Self.automationLaneHeight,
                    range: param.range),
                contentWidth: contentWidth,
                onCommit: { points in onCommitPoints(track.id, lane.id, points) }
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

    /// Resolves a live drop point into its hover preview: the snapped landing beat +
    /// the target lane (highlighted only when a SINGLE file lands on an existing
    /// audio lane — the plan's routing rule, shared so the preview never drifts from
    /// what the drop will actually do). `rawBeat` is fed to the callback unsnapped.
    private func resolveDropHover(at point: CGPoint, fileCount: Int) -> AudioDropHover {
        let rawBeat = max(0, Double(point.x / Self.pixelsPerBeat))
        let snapped = effectiveSnap.snap(beat: rawBeat, meterMap: meterMap)
        let index = trackIndex(atContentY: point.y)
        let kind = index.map { tracks[$0].kind }
        let landsOnLane = AudioImportPlan.routesToExistingAudioTrack(
            fileCount: fileCount, targetKind: kind)
        return AudioDropHover(
            targetTrackID: index.map { tracks[$0].id },
            targetLaneIndex: landsOnLane ? index : nil,
            snappedBeat: snapped,
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
                .offset(x: CGFloat(hover.snappedBeat) * Self.pixelsPerBeat)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Playhead (offset view; no Canvas redraw on transport ticks)

    private var playhead: some View {
        Rectangle()
            .fill(DAWTheme.playback)
            .frame(width: 1.5, height: contentHeight)
            .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
            .offset(x: CGFloat(positionBeats) * Self.pixelsPerBeat)
            .allowsHitTesting(false)
    }

    // MARK: - Loop region band + ruler (beta m10-g)

    /// The committed loop region, or nil when none exists — the transport model
    /// always keeps `end > start` once set, so nil is the untouched/preview case
    /// (0…0). nil renders no band and makes the whole ruler a sketch/seek surface.
    private var loopRegion: LoopRegion? {
        loopEndBeat > loopStartBeat ? LoopRegion(start: loopStartBeat, end: loopEndBeat) : nil
    }

    private var loopGeometry: LoopRulerGeometry {
        LoopRulerGeometry(pixelsPerBeat: Self.pixelsPerBeat)
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
            let startX = CGFloat(region.start) * Self.pixelsPerBeat
            let w = max(3, CGFloat(region.end - region.start) * Self.pixelsPerBeat)
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
                    let delta = Double((curX - value.startLocation.x) / Self.pixelsPerBeat)
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
        MarkerLaneGeometry(pixelsPerBeat: Self.pixelsPerBeat)
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
            pixelsPerBeat: Self.pixelsPerBeat,
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
                let delta = Double(translationWidth / Self.pixelsPerBeat)
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
    var isSelected: Bool
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
    var onSelect: () -> Void
    var onMove: (_ toStartBeat: Double) -> Void
    var onTrim: (_ newStart: Double, _ newLength: Double) -> Void
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

    // MARK: Crossfade (m11-d)

    /// The id of this clip's eligible crossfade partner — the adjacent-or-
    /// overlapping ordinary AUDIO clip to its right — or nil when there is none
    /// (then the "Crossfade with Next" menu is hidden). Audio + Pro only.
    var crossfadeNextClipID: UUID? = nil
    /// Crossfades this clip with its right neighbour by the given beat length
    /// (wired to `ProjectStore.crossfadeClips`, one undo step).
    var onCrossfadeWithNext: (_ lengthBeats: Double) -> Void = { _ in }

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
    private var showGain: Bool { pro && width > 40 && (clip.gainDb != 0 || hovering || isSelected) }

    // MARK: - Gain envelope overlay (m13-e)

    /// The per-clip gain-envelope breakpoint overlay shows on a SELECTED AUDIO
    /// clip in PRO density only (docs/DESIGN-LANGUAGE.md "Panels" — Simple hides
    /// clip-edit chrome). Selecting the clip IS the envelope-edit mode; the
    /// overlay only hit-tests its breakpoint dots, so the clip body's
    /// move/split/trim/select gestures pass through untouched between dots.
    private var showGainEnvelope: Bool { pro && !clip.isMIDI && isSelected }
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
            .onTapGesture { onSelect() }
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
            let newStart = ClipEdit.movedStartBeat(
                originalStart: active.originStart, dragDeltaBeats: dxBeats,
                snap: snap, meterMap: meterMap)
            onMove(newStart)
            readout = "start " + fmt(newStart)
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
        // Simple a non-take clip has no context menu (empty builder → no menu).
        if pro {
            Button("Split at Playhead") {
                if let beat = ClipEdit.snappedSplit(
                    timelineBeatRaw: playheadBeat, clipStart: clip.startBeat,
                    clipLength: clip.lengthBeats, snap: snap, meterMap: meterMap) {
                    onSplit(beat)
                }
            }
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
        }
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
