import SwiftUI
import DAWCore
import DAWAppKit

/// The arrange TEMPO LANE strip (m12-d, design §3.8) — a rendering + gesture
/// layer over `TempoLaneModel`, seated in the ruler block below the marker lane.
/// Renders the tempo map's segments (bpm labels + boundary handles) and the
/// meter map's flags; Pro edits them (drag a boundary, scrub a bpm, add/remove a
/// segment, set a meter), Simple is read-only. Every mutation routes through the
/// model → `ProjectStore.setTempoMap`, so the wire/UI stay equivalent and a drag
/// coalesces to ONE undo.
///
/// NO VIOLET (Rule 3 — tempo is standard timeline chrome, not AI content). Cyan
/// (`DAWTheme.playback`) marks only earned active state: the selected segment and
/// a live handle. Neutral dark glass otherwise; the bpm/meter readouts are SF Mono
/// (docs/DESIGN-LANGUAGE.md digital-readout rule).
struct TempoLaneBand: View {
    let model: TempoLaneModel
    let tempoMap: TempoMap
    let meterMap: MeterMap
    let pixelsPerBeat: CGFloat
    let height: CGFloat
    /// Full content width (points) — the last segment fills to here.
    let contentWidth: CGFloat
    /// The arrange effective snap (Bar in Simple, the picked grid in Pro) — the
    /// same grid the ruler/loop/marker surfaces snap to.
    let snap: ClipSnap
    /// Pro reveals editing (handles + gestures + context menu); Simple is read-only.
    let isPro: Bool
    /// While recording, map edits are refused — the lane greys to match.
    let isRecording: Bool
    let contentSpace: String

    /// A boundary drag in flight: which segment's boundary, so per-tick math is
    /// stable and the coalesced drag reads as one undo.
    @State private var boundaryDragIndex: Int?
    /// A bpm scrub in flight: the segment + its bpm at press (delta is applied to
    /// this, not the live-updating value, so the scrub is stable).
    @State private var bpmDrag: (index: Int, startBPM: Double)?
    /// The last content beat the pointer hovered — where "Add Tempo Change Here"
    /// and a double-click insert land.
    @State private var hoverBeat: Double = 0

    private var geometry: TempoLaneGeometry {
        TempoLaneGeometry(pixelsPerBeat: pixelsPerBeat)
    }

    /// Vertical-drag sensitivity: points of drag per 1 BPM (drag UP = faster).
    private static let bpmDragPointsPerBPM: CGFloat = 1.5
    private static let handleHitWidth: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topLeading) {
            segments
            if isPro && !isRecording { boundaryHandles }
            meterFlags
        }
        .frame(width: contentWidth, height: height, alignment: .topLeading)
        .opacity(isRecording ? 0.5 : 1)
        .explainable(.tempoMap)
        .help(isPro
              ? "Tempo lane — drag a boundary to move a tempo change, drag a section up/down to change its BPM, double-click to add one, right-click for meter changes"
              : "Tempo lane — the song's tempo sections and time signatures (switch to Pro to edit)")
    }

    // MARK: - Segments (bpm labels + scrub/add/remove surface)

    private var segments: some View {
        ForEach(Array(tempoMap.segments.enumerated()), id: \.offset) { index, segment in
            let startX = geometry.x(forBeat: segment.startBeat)
            let endX = index + 1 < tempoMap.segments.count
                ? geometry.x(forBeat: tempoMap.segments[index + 1].startBeat)
                : contentWidth
            segmentBody(index: index, bpm: segment.bpm, width: max(2, endX - startX))
                .offset(x: startX)
        }
    }

    @ViewBuilder
    private func segmentBody(index: Int, bpm: Double, width: CGFloat) -> some View {
        let selected = model.selectedSegmentIndex == index
        let accent = DAWTheme.playback
        RoundedRectangle(cornerRadius: 3)
            .fill(DAWTheme.panelRaised.opacity(selected ? 0.95 : 0.7))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(selected ? accent.opacity(0.9) : DAWTheme.hairline, lineWidth: 1)
            )
            // BPM readout in the bottom-left of the strip (SF Mono). The top strip
            // is reserved for meter flags so the two never collide.
            .overlay(alignment: .bottomLeading) {
                Text("\(Int(bpm.rounded()))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? accent : DAWTheme.textSecondary)
                    .padding(.leading, 5)
                    .padding(.bottom, 1)
            }
            .frame(width: width, height: height)
            .glow(accent, radius: 4, intensity: selected ? 0.35 : 0)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named(contentSpace)) { phase in
                if case .active(let p) = phase { hoverBeat = geometry.beat(forX: p.x) }
            }
            .onTapGesture { model.selectSegment(index) }
            .modifier(SegmentEditGestures(
                enabled: isPro && !isRecording, index: index, bpm: bpm,
                addBeat: hoverBeat, snap: snap, bpmDrag: $bpmDrag,
                model: model, sensitivity: Self.bpmDragPointsPerBPM))
            .contextMenu {
                if isPro && !isRecording { segmentMenu(index: index) }
            }
    }

    @ViewBuilder
    private func segmentMenu(index: Int) -> some View {
        Button("Add Tempo Change Here") {
            model.addSegment(atBeat: hoverBeat, snap: snap)
        }
        if index >= 1 {
            Button("Remove This Tempo Change", role: .destructive) {
                model.removeSegment(index: index)
            }
        }
        Divider()
        Button("Set 3/4 Here") { model.setMeter(atBeat: hoverBeat, beatsPerBar: 3, beatUnit: 4) }
        Button("Set 4/4 Here") { model.setMeter(atBeat: hoverBeat, beatsPerBar: 4, beatUnit: 4) }
        Button("Set 7/8 Here") { model.setMeter(atBeat: hoverBeat, beatsPerBar: 7, beatUnit: 8) }
        Button("Remove Meter Change Here") { model.removeMeter(atBeat: hoverBeat) }
    }

    // MARK: - Boundary handles (drag to move a tempo change; Pro only)

    private var boundaryHandles: some View {
        ForEach(1..<max(1, tempoMap.segments.count), id: \.self) { index in
            let x = geometry.x(forBeat: tempoMap.segments[index].startBeat)
            boundaryHandle(index: index)
                .offset(x: x - Self.handleHitWidth / 2)
        }
    }

    private func boundaryHandle(index: Int) -> some View {
        let active = boundaryDragIndex == index
        let accent = DAWTheme.playback
        return RoundedRectangle(cornerRadius: 1)
            .fill(active ? accent : DAWTheme.textDim)
            .frame(width: 3, height: height)
            .glow(accent, radius: 3, intensity: active ? 0.55 : 0)
            .frame(width: Self.handleHitWidth, height: height)
            .contentShape(Rectangle())
            .hoverCursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(contentSpace))
                    .onChanged { value in
                        boundaryDragIndex = index
                        model.dragBoundary(index: index, toBeat: geometry.beat(forX: value.location.x), snap: snap)
                    }
                    .onEnded { _ in boundaryDragIndex = nil }
            )
    }

    // MARK: - Meter flags (top strip)

    private var meterFlags: some View {
        ForEach(Array(meterMap.changes.enumerated()), id: \.offset) { _, change in
            meterFlag("\(change.beatsPerBar)/\(change.beatUnit)")
                .offset(x: geometry.x(forBeat: change.startBeat) + 2, y: 0)
        }
    }

    private func meterFlag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(DAWTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(DAWTheme.hairline, lineWidth: 0.5))
            )
    }
}

/// The segment-body edit gestures (Pro): a vertical drag scrubs the segment's
/// bpm and a double-click inserts a tempo change. Factored into a modifier so the
/// read-only (Simple) path adds no gesture at all — a dead, honest surface. The
/// drag uses a small minimum distance so a tap (select) / double-tap (add) still
/// register.
private struct SegmentEditGestures: ViewModifier {
    let enabled: Bool
    let index: Int
    let bpm: Double
    /// The live hover beat (from the body's `onContinuousHover`) — where a
    /// double-click inserts a tempo change.
    let addBeat: Double
    let snap: ClipSnap
    @Binding var bpmDrag: (index: Int, startBPM: Double)?
    let model: TempoLaneModel
    let sensitivity: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(count: 2) { model.addSegment(atBeat: addBeat, snap: snap) }
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            let start: Double
                            if let d = bpmDrag, d.index == index { start = d.startBPM }
                            else { start = bpm; bpmDrag = (index, bpm) }
                            let delta = Double(-value.translation.height / sensitivity)
                            model.scrubBPM(index: index, toBPM: start + delta)
                        }
                        .onEnded { _ in bpmDrag = nil }
                )
        } else {
            content
        }
    }
}
