import SwiftUI
import DAWCore
import DAWAppKit

/// The expanded take-lanes region under a track's clip lane (M5 iii-c): one
/// stacked group block per `TakeGroup`, each a small header (name + lane count +
/// Flatten) over one sub-row per lane. A lane row draws its take material dim
/// (mini waveform / MIDI dots via the shared `ClipWaveform` idiom) with the
/// comp's selected regions glowing over it; the newest lane reads distinct.
///
/// Interactions (docs/DESIGN-LANGUAGE.md "Glass Cockpit", the automation-lane
/// precedent): drag horizontally on a lane row to PAINT that lane into the comp
/// over the snapped beat range (coalesced `take.comp:<id>` commits, per-tick
/// safe); a click without a drag SELECTs the whole lane. Thin over the headless
/// `TakeLaneGeometry` / `TakeComp` — all mutations go out through the callbacks
/// (each wired to one `ProjectStore` take method, so undo/coalescing come free).
struct TakeLanesView: View {
    var track: Track
    var geometry: TakeLaneGeometry
    var contentWidth: CGFloat
    var snap: ClipSnap
    /// Project meter map (m13-h): comp paint snaps route through it so a paint in
    /// an odd-meter region snaps on that region's grid.
    var meterMap: MeterMap
    var secondsPerBeat: Double
    var waveformStore: WaveformStore
    /// Replaces a group's comp wholesale (wired to `setCompSegments`).
    var onSetComp: (_ groupID: UUID, _ segments: [CompSegment]) -> Void
    /// Whole-lane swap (wired to `selectTake`).
    var onSelectLane: (_ groupID: UUID, _ laneID: UUID) -> Void
    /// Dissolves the group into ordinary clips (wired to `flattenTakeGroup`).
    var onFlatten: (_ groupID: UUID) -> Void
    /// Deletes a lane (wired to `removeTakeLane`).
    var onRemoveLane: (_ groupID: UUID, _ laneID: UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(track.takeGroups) { group in
                groupBlock(group)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func groupBlock(_ group: TakeGroup) -> some View {
        VStack(spacing: 0) {
            groupHeader(group)
            ForEach(Array(group.lanes.enumerated()), id: \.element.id) { index, lane in
                TakeLaneRow(
                    group: group,
                    lane: lane,
                    isNewest: index == group.lanes.count - 1,
                    geometry: geometry,
                    contentWidth: contentWidth,
                    snap: snap,
                    meterMap: meterMap,
                    secondsPerBeat: secondsPerBeat,
                    waveformPeaks: lane.clip.audioFileURL.flatMap { waveformStore.peaks(for: $0) },
                    onSetComp: { onSetComp(group.id, $0) },
                    onSelectLane: { onSelectLane(group.id, lane.id) },
                    onRemoveLane: { onRemoveLane(group.id, lane.id) },
                    onSelectTake: { onSelectLane(group.id, $0) },
                    onFlatten: { onFlatten(group.id) }
                )
            }
        }
    }

    /// Group header strip: a violet-free take glyph, the group name, its lane
    /// count, and a Flatten button (the escape hatch to ordinary clips).
    private func groupHeader(_ group: TakeGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DAWTheme.signal)
            Text(group.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            Text("\(group.lanes.count) takes")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
            Spacer(minLength: 0)
            Button { onFlatten(group.id) } label: {
                Text("FLATTEN")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(DAWTheme.textDim)
                    .padding(.horizontal, 6)
                    .frame(height: 14)
                    .background(DAWTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Flatten this take group into ordinary, editable clips")
            .padding(.trailing, 8)
        }
        .padding(.leading, 8)
        .frame(width: contentWidth, height: TimelineLanesView.takeGroupHeaderHeight, alignment: .leading)
        .background(DAWTheme.background.opacity(0.35))
    }
}

/// One lane sub-row: dim take material with the comp's selected regions glowing,
/// a name tag (brighter for the newest lane), and the paint/select gesture.
private struct TakeLaneRow: View {
    var group: TakeGroup
    var lane: TakeLane
    var isNewest: Bool
    var geometry: TakeLaneGeometry
    var contentWidth: CGFloat
    var snap: ClipSnap
    var meterMap: MeterMap
    var secondsPerBeat: Double
    var waveformPeaks: WaveformPeaks?
    var onSetComp: (_ segments: [CompSegment]) -> Void
    var onSelectLane: () -> Void
    var onRemoveLane: () -> Void
    var onSelectTake: (_ laneID: UUID) -> Void
    var onFlatten: () -> Void

    /// Captured at drag start so per-tick paint recomputes from the original comp
    /// (no compounding) while commits stream through the coalescing store op.
    @State private var paintStartBeat: Double?
    @State private var baseComp: [CompSegment]?

    private var tint: Color {
        if lane.clip.isAIGenerated { return DAWTheme.ai }
        return lane.clip.isMIDI ? DAWTheme.playback : DAWTheme.signal
    }

    private var rowHeight: CGFloat { geometry.rowHeight }
    private var laneClipX: CGFloat { geometry.x(forBeat: lane.clip.startBeat) }
    private var laneClipW: CGFloat { max(2, CGFloat(lane.clip.lengthBeats) * geometry.pixelsPerBeat) }
    private var selectedSegments: [CompSegment] { TakeComp.segments(forLane: lane.id, comp: group.comp) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(DAWTheme.background.opacity(0.4))
            // Newest lane: a thin left accent so the freshest take reads distinct.
            if isNewest {
                Rectangle()
                    .fill(tint.opacity(0.7))
                    .frame(width: 2)
            }
            material
            highlights
            nameTag
        }
        .frame(width: contentWidth, height: rowHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DAWTheme.hairline.opacity(0.5)).frame(height: 1)
        }
        .contentShape(Rectangle())
        // Pointer affordance (docs/DESIGN-LANGUAGE.md): a take lane is a place/paint
        // surface — click selects it, drag paints it into the comp → crosshair.
        .hoverCursor(.crosshair)
        .gesture(paintDrag)
        .contextMenu { menu }
        .help("Take “\(lane.name)” — drag to paint into the comp, click to select the whole take")
    }

    /// Dim take material: a faded waveform outline for audio, faded note dots for
    /// MIDI, windowed/positioned by the lane clip's absolute beats.
    @ViewBuilder
    private var material: some View {
        if lane.clip.isMIDI {
            // The shared arrange note map (beta m10-f), faded to 0.5 for the dim
            // take-lane look — 0.8 pill × 0.5 = the strip's original 0.4 weight, so
            // no visual regression while both renderings share one geometry.
            ClipMIDIMap(notes: lane.clip.notes ?? [], lengthBeats: lane.clip.lengthBeats,
                        pixelsPerBeat: geometry.pixelsPerBeat, tint: tint)
                .frame(width: laneClipW, height: rowHeight)
                .offset(x: laneClipX)
                .opacity(0.5)
                .allowsHitTesting(false)
        } else if let peaks = waveformPeaks {
            ClipWaveform(peaks: peaks, startOffsetSeconds: lane.clip.startOffsetSeconds,
                         secondsPerBeat: secondsPerBeat, pixelsPerBeat: geometry.pixelsPerBeat, tint: tint)
                .frame(width: laneClipW, height: rowHeight)
                .offset(x: laneClipX)
                .opacity(0.45)
                .allowsHitTesting(false)
        }
    }

    /// The glowing comp regions — the parts of this lane the comp actually plays.
    private var highlights: some View {
        ForEach(Array(selectedSegments.enumerated()), id: \.offset) { _, seg in
            let rect = geometry.segmentRect(startBeat: seg.startBeat, endBeat: seg.endBeat, rowIndex: 0)
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint.opacity(0.9), lineWidth: 1))
                .glow(tint, radius: 4, intensity: 0.45)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.origin.x, y: rect.origin.y)
                .allowsHitTesting(false)
        }
    }

    private var nameTag: some View {
        Text(lane.name)
            .font(.system(size: 8, weight: isNewest ? .bold : .medium, design: .monospaced))
            .foregroundStyle(isNewest ? tint : DAWTheme.textDim)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(DAWTheme.panel.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(.leading, 5)
            .padding(.top, 2)
            .allowsHitTesting(false)
    }

    // MARK: - Paint / select gesture

    private var paintDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                DragCursor.set(.crosshair)
                if paintStartBeat == nil {
                    paintStartBeat = geometry.beat(forX: value.startLocation.x)
                    baseComp = group.comp
                }
                let g = classify(fromBeat: paintStartBeat ?? 0, toX: value.location.x)
                if !g.isClick {
                    let next = TakeComp.paint(baseComp ?? group.comp, laneID: lane.id,
                                              startBeat: g.startBeat, endBeat: g.endBeat,
                                              range: group.rangeBeats)
                    onSetComp(next)
                }
            }
            .onEnded { value in
                let start = paintStartBeat ?? geometry.beat(forX: value.startLocation.x)
                let g = classify(fromBeat: start, toX: value.location.x)
                if g.isClick { onSelectLane() }
                paintStartBeat = nil
                baseComp = nil
                DragCursor.clear()
            }
    }

    private func classify(fromBeat: Double, toX: CGFloat) -> TakePaintGesture {
        TakeComp.classifyDrag(
            laneID: lane.id, fromBeatRaw: fromBeat, toBeatRaw: geometry.beat(forX: toX),
            snap: snap, meterMap: meterMap, range: group.rangeBeats)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Select This Take") { onSelectLane() }
        Divider()
        ForEach(group.lanes) { other in
            Button("Select \(other.name)") { onSelectTake(other.id) }
        }
        Divider()
        Button("Remove \(lane.name)", role: .destructive) { onRemoveLane() }
        Button("Flatten Group") { onFlatten() }
    }
}
