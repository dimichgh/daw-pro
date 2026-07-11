import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

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
    var beatsPerBar: Int
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
    /// Clip edits — each wired to one of the five `ProjectStore` clip methods.
    var onMoveClip: (_ trackID: UUID, _ clip: Clip, _ toStartBeat: Double) -> Void = { _, _, _ in }
    var onTrimClip: (_ trackID: UUID, _ clip: Clip, _ newStart: Double, _ newLength: Double) -> Void = { _, _, _, _ in }
    var onSplitClip: (_ trackID: UUID, _ clip: Clip, _ atBeat: Double) -> Void = { _, _, _ in }
    var onSetClipFades: (_ trackID: UUID, _ clip: Clip, _ fadeIn: Double, _ fadeOut: Double,
                         _ inCurve: FadeCurve, _ outCurve: FadeCurve) -> Void = { _, _, _, _, _, _ in }
    var onSetClipGain: (_ trackID: UUID, _ clip: Clip, _ gainDb: Double) -> Void = { _, _, _ in }
    /// The stretch HANDLE (M5 ii-e): alt-drag the right edge of an AUDIO clip to
    /// retarget its timeline length while holding the source window (wired to
    /// `ProjectStore.stretchClip`, NOT trim). MIDI right-edge alt-drag stays trim.
    var onStretchClip: (_ trackID: UUID, _ clip: Clip, _ toLengthBeats: Double) -> Void = { _, _, _ in }
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

    /// Stationary content coordinate space — clip drags measure against this so a
    /// block moving under the cursor never feeds its own translation back.
    static let contentSpace = "arrangeContent"

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
    static let rulerHeight: CGFloat = 42
    static let laneHeight: CGFloat = 34
    static let laneSpacing: CGFloat = 6
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
        let bars = Int((lastClipEnd / Double(beatsPerBar)).rounded(.up)) + 2
        return max(bars * beatsPerBar, 32)   // always show a few empty bars
    }

    private var contentWidth: CGFloat { CGFloat(totalBeats) * Self.pixelsPerBeat }

    /// Extra height a track contributes below its clip lane: its takes section
    /// (directly under the clips) then its automation row (the same order the
    /// sidebar stacks its control panels, so both columns stay aligned).
    private func extraHeight(_ track: Track) -> CGFloat {
        takesHeight(track) + (isExpanded(track) ? Self.automationLaneHeight : 0)
    }

    private var contentHeight: CGFloat {
        var y = Self.rulerHeight
        for track in tracks {
            y += rowHeight + extraHeight(track) + Self.laneSpacing
        }
        return y
    }

    /// Top y of track `index`'s clip lane, accounting for expanded tracks above.
    private func laneTop(_ index: Int) -> CGFloat {
        var y = Self.rulerHeight
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                grid
                clipBlocks
                takeLanes
                automationLanes
                playhead
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            .coordinateSpace(name: Self.contentSpace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel()
    }

    // MARK: - Grid + ruler (Canvas — no per-frame allocation beyond Paths)

    private var grid: some View {
        Canvas { context, size in
            // Lane backgrounds.
            for index in tracks.indices {
                let rect = CGRect(x: 0, y: laneTop(index), width: size.width, height: rowHeight)
                context.fill(Path(rect), with: .color(DAWTheme.panelRaised.opacity(0.4)))
            }

            // Vertical beat/bar lines.
            var beatLines = Path()
            var barLines = Path()
            for beat in 0...totalBeats {
                let x = CGFloat(beat) * Self.pixelsPerBeat
                let line = CGRect(x: x, y: 0, width: 1, height: size.height)
                if beat % beatsPerBar == 0 {
                    barLines.addRect(line)
                } else {
                    beatLines.addRect(line)
                }
            }
            context.fill(beatLines, with: .color(DAWTheme.hairline))
            context.fill(barLines, with: .color(DAWTheme.gridEmphasis))

            // Ruler baseline + bar numbers (SF Mono digital readout).
            context.fill(
                Path(CGRect(x: 0, y: Self.rulerHeight - 1, width: size.width, height: 1)),
                with: .color(DAWTheme.hairline)
            )
            var bar = 1
            var beat = 0
            while beat <= totalBeats {
                let text = Text("\(bar)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(DAWTheme.textDim)
                context.draw(
                    text,
                    at: CGPoint(x: CGFloat(beat) * Self.pixelsPerBeat + 4, y: Self.rulerHeight - 12),
                    anchor: .topLeading
                )
                bar += 1
                beat += beatsPerBar
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
                    beatsPerBar: beatsPerBar,
                    secondsPerBeat: secondsPerBeat,
                    playheadBeat: positionBeats,
                    waveformPeaks: clip.audioFileURL.flatMap { waveformStore.peaks(for: $0) },
                    renderVisual: ClipStretch.renderVisual(for: stretchStatus(clip)),
                    onSelect: { onSelectClip(clip) },
                    onMove: { onMoveClip(track.id, clip, $0) },
                    onTrim: { onTrimClip(track.id, clip, $0, $1) },
                    onSplit: { onSplitClip(track.id, clip, $0) },
                    onSetFades: { onSetClipFades(track.id, clip, $0, $1, $2, $3) },
                    onSetGain: { onSetClipGain(track.id, clip, $0) },
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

    // MARK: - Take lanes (per expanded track with groups, beat-aligned)

    private var takeLanes: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if isTakesExpanded(track) {
                TakeLanesView(
                    track: track,
                    geometry: takeGeometry,
                    contentWidth: contentWidth,
                    snap: snap,
                    beatsPerBar: beatsPerBar,
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

    // MARK: - Playhead (offset view; no Canvas redraw on transport ticks)

    private var playhead: some View {
        Rectangle()
            .fill(DAWTheme.playback)
            .frame(width: 1.5, height: contentHeight)
            .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
            .offset(x: CGFloat(positionBeats) * Self.pixelsPerBeat)
            .allowsHitTesting(false)
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
    var beatsPerBar: Int
    var secondsPerBeat: Double
    var playheadBeat: Double
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
    /// Live ⌥ state while hovering (drives the stretch-handle grip cue). Tracked
    /// by a flags-changed monitor installed only while the pointer is over the
    /// block, so at most one clip carries a monitor at a time.
    @State private var optionHeld = false
    @State private var flagsMonitor: Any?

    private var ppb: CGFloat { geometry.pixelsPerBeat }
    private var clipOriginX: CGFloat { CGFloat(clip.startBeat) * ppb }
    /// Pro-only (sp-c): the gain dB chip and its drag are a clip-edit affordance.
    private var showGain: Bool { pro && width > 40 && (clip.gainDb != 0 || hovering || isSelected) }

    /// Amber hint: this clip is stretched OUTSIDE the 0.75–1.5× transparent band
    /// (docs/DESIGN-LANGUAGE.md amber = warning; never a hard block).
    private var outOfBand: Bool { ClipStretch.isOutOfBand(ratio: clip.stretchRatio) }
    /// Persistent ratio/pitch badge for a non-identity clip (nil for identity).
    private var badgeText: String? {
        ClipStretch.badge(ratio: clip.stretchRatio, semitones: clip.pitchShiftSemitones)
    }
    /// Border/glow accent: red on render failure, amber out-of-band, else the
    /// clip tint. One accent per meaning (design rule 3).
    private var borderColor: Color {
        if renderVisual == .error { return DAWTheme.clip }
        if outOfBand { return DAWTheme.record }
        return tint
    }
    private var strokeOpacity: Double {
        if isSelected { return 0.95 }
        if outOfBand || renderVisual == .error { return 0.85 }
        return 0.55
    }
    private var strokeWidth: CGFloat {
        (isSelected || outOfBand || renderVisual == .error) ? 1.5 : 1
    }
    private var glowIntensity: Double {
        if renderVisual == .error { return 0.55 }
        if outOfBand { return 0.4 }
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
        return outOfBand ? base + "\n" + ClipStretch.outOfBandHelp(ratio: clip.stretchRatio) : base
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(tint.opacity(isSelected ? 0.34 : 0.22))
            .overlay { waveform }
            .overlay { noteMap }
            .overlay { shimmer }
            .overlay { decorations }
            .overlay(alignment: .leading) { label }
            .overlay(alignment: .trailing) { stretchGrip }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(borderColor.opacity(strokeOpacity), lineWidth: strokeWidth)
            )
            .overlay(alignment: .topTrailing) { stretchBadge }
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
        } else if !clip.isMIDI {
            // Audio honesty (beta m10-f): while the peaks load off-main (or the file
            // is unreadable → computePeaks nil), show a dim flat center line so an
            // audio clip never reads as blank. Minimal on purpose — no shimmer (that
            // idiom means "stretch working"), no redesign.
            Rectangle()
                .fill(tint.opacity(0.3))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
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
                tint: tint
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
        Canvas { context, size in
            let gripBright = (hovering || isSelected) ? 0.9 : 0.4
            if clip.fadeInBeats > 0 {
                context.fill(fadeInPath(width: size.width, height: size.height, curve: clip.fadeInCurve),
                             with: .color(DAWTheme.background.opacity(0.5)))
            }
            if clip.fadeOutBeats > 0 {
                context.fill(fadeOutPath(width: size.width, height: size.height, curve: clip.fadeOutCurve),
                             with: .color(DAWTheme.background.opacity(0.5)))
            }
            // Grips at each fade's inner end (at the corner when the fade is 0).
            let fiX = geometry.fadeInHandleX(fadeInBeats: clip.fadeInBeats, clipWidth: size.width)
            let foX = geometry.fadeOutHandleX(fadeOutBeats: clip.fadeOutBeats, clipWidth: size.width)
            context.fill(gripTriangle(atX: fiX), with: .color(tint.opacity(gripBright)))
            context.fill(gripTriangle(atX: foX), with: .color(tint.opacity(gripBright)))
        }
        .allowsHitTesting(false)
        }
    }

    /// Rising fade factor 0→1 for progress `t` (linear = t, equal-power = sine).
    private func fadeShape(_ t: Double, _ curve: FadeCurve) -> Double {
        let p = t.clamped(to: 0...1)
        return curve == .linear ? p : sin(p * .pi / 2)
    }

    /// Dimmed region above the rising fade-in curve (top-left) — straight for
    /// linear, bowed for equal-power.
    private func fadeInPath(width w: CGFloat, height h: CGFloat, curve: FadeCurve) -> Path {
        let fadeW = min(CGFloat(clip.fadeInBeats) * ppb, w)
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
    private func fadeOutPath(width w: CGFloat, height h: CGFloat, curve: FadeCurve) -> Path {
        let fadeW = min(CGFloat(clip.fadeOutBeats) * ppb, w)
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

    private func gripTriangle(atX x: CGFloat) -> Path {
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
                        dragDeltaBeats: dxBeats, snap: snap, beatsPerBar: beatsPerBar)
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
                snap: snap, beatsPerBar: beatsPerBar)
            onMove(newStart)
            readout = "start " + fmt(newStart)
        case .trimStart:
            let (s, l) = ClipEdit.trimStart(
                originalStart: active.originStart, originalLength: active.originLength,
                newStartBeatRaw: active.originStart + dxBeats, snap: snap, beatsPerBar: beatsPerBar)
            onTrim(s, l)
            readout = "start " + fmt(s) + "  len " + fmt(l)
        case .trimEnd:
            let (s, l) = ClipEdit.trimEnd(
                originalStart: active.originStart,
                newEndBeatRaw: active.originStart + active.originLength + dxBeats,
                snap: snap, beatsPerBar: beatsPerBar)
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
                    clipLength: clip.lengthBeats, snap: snap, beatsPerBar: beatsPerBar) {
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
                    clipLength: clip.lengthBeats, snap: snap, beatsPerBar: beatsPerBar) {
                    onSplit(beat)
                }
            }
            Button("Reset Gain") { onSetGain(0) }
                .disabled(clip.gainDb == 0)
            Divider()
            Button(clip.fadeInCurve == .linear ? "Fade In: Equal Power" : "Fade In: Linear") {
                onSetFades(clip.fadeInBeats, clip.fadeOutBeats,
                           ClipEdit.toggledCurve(clip.fadeInCurve), clip.fadeOutCurve)
            }
            Button(clip.fadeOutCurve == .linear ? "Fade Out: Equal Power" : "Fade Out: Linear") {
                onSetFades(clip.fadeInBeats, clip.fadeOutBeats,
                           clip.fadeInCurve, ClipEdit.toggledCurve(clip.fadeOutCurve))
            }
        }
    }

    /// Compact beat readout for the drag bubble (2 decimals, trailing zeros trimmed).
    private func fmt(_ beats: Double) -> String {
        String(format: "%.2f", beats)
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
