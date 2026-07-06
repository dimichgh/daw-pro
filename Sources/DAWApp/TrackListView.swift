import SwiftUI
import DAWCore
import DAWAppKit

struct TrackListView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TRACKS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(DAWTheme.textDim)
                Spacer()
                Button {
                    store.addTrack()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DAWTheme.playback)
                        .frame(width: 22, height: 22)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Add track")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if store.tracks.isEmpty {
                VStack(spacing: 6) {
                    Text("No tracks yet")
                        .font(.system(size: 12))
                        .foregroundStyle(DAWTheme.textDim)
                    Text("Add one, or let an agent do it over MCP")
                        .font(.system(size: 10))
                        .foregroundStyle(DAWTheme.textDim.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.tracks) { track in
                            TrackRow(track: track)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }
}

struct TrackRow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    var track: Track

    private var kindIcon: String {
        switch track.kind {
        case .audio: "waveform"
        case .instrument: "pianokeys"
        case .bus: "arrow.triangle.merge"
        }
    }

    private var isExpanded: Bool { model.expandedAutomationTrackIDs.contains(track.id) }
    /// Takes section shows only when expanded AND the track has groups (mirrors
    /// the timeline's `isTakesExpanded`).
    private var isTakesExpanded: Bool {
        model.expandedTakeTrackIDs.contains(track.id) && !track.takeGroups.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            row
            if isTakesExpanded {
                TakeTrackControls(track: track)
            }
            if isExpanded {
                AutomationTrackControls(track: track)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(
                track.isAIGenerated ? DAWTheme.ai.opacity(0.35) : DAWTheme.hairline,
                lineWidth: 1
            )
        )
        .contextMenu {
            Button("Remove Track", role: .destructive) {
                store.removeTrack(id: track.id)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: kindIcon)
                .font(.system(size: 11))
                .foregroundStyle(track.isAIGenerated ? DAWTheme.ai : DAWTheme.textDim)
                .frame(width: 16)

            Text(track.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            MiniLevelBar(meter: store.trackMeters[track.id] ?? .silence)

            if track.clips.count > 0 {
                Text("\(track.clips.count) ♪")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
            }

            takesDisclosure

            automationDisclosure

            ToggleChip(label: "M", isOn: track.isMuted, onColor: DAWTheme.record) {
                store.setTrackMute(id: track.id, muted: !track.isMuted)
            }
            ToggleChip(label: "S", isOn: track.isSoloed, onColor: DAWTheme.playback) {
                store.setTrackSolo(id: track.id, soloed: !track.isSoloed)
            }
            if track.kind == .audio || track.kind == .instrument {
                // Record arm (audio capture / MIDI capture + live thru) —
                // throws only for bus tracks, which never show the chip.
                ToggleChip(label: "R", isOn: track.isArmed, onColor: DAWTheme.record) {
                    _ = try? store.setTrackArm(id: track.id, armed: !track.isArmed)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Automation disclosure: an axis-chart glyph that opens the track's
    /// breakpoint editor row. Glows cyan when the track has an active (enabled,
    /// non-empty) lane; outlined while the row is open.
    private var automationDisclosure: some View {
        let active = AutomationLaneSelection.hasActiveLane(track)
        return Button {
            model.toggleAutomation(track.id)
        } label: {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(active || isExpanded ? DAWTheme.playback : DAWTheme.textDim)
                .frame(width: 20, height: 18)
                .background((active || isExpanded) ? DAWTheme.playback.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        isExpanded ? DAWTheme.playback.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
                )
                .glow(DAWTheme.playback, radius: 4, intensity: active ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help("Automation — draw volume or pan over time")
    }

    /// Takes disclosure (M5 iii-c): a stacked-layers glyph that opens the track's
    /// take-lanes section. Shown only when the track HAS take groups (nothing to
    /// comp otherwise); glows signal-green because a group exists, outlined while
    /// the section is open.
    @ViewBuilder
    private var takesDisclosure: some View {
        if TakeLaneSelection.hasTakeGroups(track) {
            Button {
                model.toggleTakes(track.id)
            } label: {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.signal)
                    .frame(width: 20, height: 18)
                    .background(DAWTheme.signal.opacity(isTakesExpanded ? 0.22 : 0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(
                            isTakesExpanded ? DAWTheme.signal.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
                    )
                    .glow(DAWTheme.signal, radius: 4, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .help("Takes — comp the best parts across recorded takes")
        }
    }
}

/// The expanded automation controls under a track header: a target picker
/// (Volume / Pan in v0), an enable toggle, and a remove button for the selected
/// lane. Sized to match the timeline's automation editor row so the two columns
/// stay aligned. All mutations route through the store's automation methods.
struct AutomationTrackControls: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    var track: Track

    private var selectedLane: AutomationLane? {
        AutomationLaneSelection.selectedLane(in: track, selection: model.automationLaneSelection[track.id])
    }

    private var selectedParam: AutomationParam? {
        selectedLane.flatMap { AutomationParam(target: $0.target) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("AUTOMATION")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
                Spacer()
                if let lane = selectedLane {
                    enableToggle(lane)
                    removeButton(lane)
                }
            }

            HStack(spacing: 6) {
                ForEach(AutomationParam.allCases, id: \.self) { param in
                    paramChip(param)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: TimelineLanesView.automationLaneHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 1)
        }
    }

    /// A target chip: lit cyan when it's the one being edited, with a small dot
    /// when a lane already exists for it. Tapping selects-or-creates its lane.
    private func paramChip(_ param: AutomationParam) -> some View {
        let isSelected = selectedParam == param
        let hasLane = AutomationLaneSelection.lane(for: param, in: track) != nil
        return Button {
            model.selectOrCreateAutomationLane(trackID: track.id, param: param)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(hasLane ? DAWTheme.playback : DAWTheme.textDim.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(param.shortLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(isSelected ? DAWTheme.playback : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? DAWTheme.playback.opacity(0.18) : DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(
                    isSelected ? DAWTheme.playback.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Automate \(param.label.lowercased())")
    }

    /// Read/manual toggle: green "ON" when the lane's drawn curve drives the
    /// engine, dim "OFF" when the fader/knob is back in the user's hands.
    private func enableToggle(_ lane: AutomationLane) -> some View {
        Button {
            _ = try? store.setAutomationLaneEnabled(
                trackID: track.id, laneID: lane.id, !lane.isEnabled)
        } label: {
            Text(lane.isEnabled ? "ON" : "OFF")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(lane.isEnabled ? DAWTheme.signal : DAWTheme.textDim)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(lane.isEnabled ? DAWTheme.signal.opacity(0.18) : DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        lane.isEnabled ? DAWTheme.signal.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
                )
                .glow(DAWTheme.signal, radius: 4, intensity: lane.isEnabled ? 0.4 : 0)
        }
        .buttonStyle(.plain)
        .help(lane.isEnabled ? "Automation on — the drawn curve drives this control"
                             : "Automation off — the fader/knob is manual")
    }

    private func removeButton(_ lane: AutomationLane) -> some View {
        Button {
            model.deleteAutomationLane(trackID: track.id, laneID: lane.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 20, height: 18)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Delete this automation lane")
    }
}

/// The expanded take controls under a track header (M5 iii-c): one block per
/// take group (name + lane count + Flatten) over a compact row per lane (name,
/// a select button, a delete button). Sized row-for-row to match the timeline's
/// take-lanes section so the sidebar and timeline stay aligned. All mutations
/// route through the store's take methods.
struct TakeTrackControls: View {
    @Environment(ProjectStore.self) private var store
    var track: Track

    var body: some View {
        VStack(spacing: 0) {
            ForEach(track.takeGroups) { group in
                groupBlock(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func groupBlock(_ group: TakeGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.signal)
                Text(group.name)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.lanes.count)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                Button {
                    _ = try? store.flattenTakeGroup(trackId: track.id, groupId: group.id)
                } label: {
                    Text("FLATTEN")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                        .padding(.horizontal, 4)
                        .frame(height: 13)
                        .background(DAWTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Flatten this take group into ordinary, editable clips")
            }
            .padding(.horizontal, 8)
            .frame(height: TimelineLanesView.takeGroupHeaderHeight)

            ForEach(Array(group.lanes.enumerated()), id: \.element.id) { index, lane in
                laneRow(group: group, lane: lane, isNewest: index == group.lanes.count - 1)
            }
        }
    }

    private func laneRow(group: TakeGroup, lane: TakeLane, isNewest: Bool) -> some View {
        let isSelected = group.comp.contains { $0.laneID == lane.id }
        return HStack(spacing: 5) {
            if isNewest {
                Rectangle().fill(DAWTheme.signal.opacity(0.7)).frame(width: 2, height: 12)
            } else {
                Spacer().frame(width: 2)
            }
            Button {
                _ = try? store.selectTake(trackId: track.id, groupId: group.id, laneId: lane.id)
            } label: {
                Circle()
                    .fill(isSelected ? DAWTheme.signal : DAWTheme.textDim.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .glow(DAWTheme.signal, radius: 3, intensity: isSelected ? 0.5 : 0)
            }
            .buttonStyle(.plain)
            .help("Select this take across the whole range")

            Text(lane.name)
                .font(.system(size: 9, weight: isNewest ? .bold : .medium, design: .monospaced))
                .foregroundStyle(isSelected ? DAWTheme.textPrimary : DAWTheme.textDim)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                _ = try? store.removeTakeLane(trackId: track.id, groupId: group.id, laneId: lane.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 8))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 18, height: 14)
                    .background(DAWTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("Delete this take (rejected while it is in use or the last take)")
        }
        .padding(.horizontal, 8)
        .frame(height: TimelineLanesView.takeLaneRowHeight)
        .background(isSelected ? DAWTheme.signal.opacity(0.08) : Color.clear)
    }
}

struct ToggleChip: View {
    var label: String
    var isOn: Bool
    var onColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? onColor : DAWTheme.textDim)
                .frame(width: 20, height: 18)
                .background(isOn ? onColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        isOn ? onColor.opacity(0.6) : DAWTheme.hairline,
                        lineWidth: 1
                    )
                )
                .glow(onColor, radius: 4, intensity: isOn ? 0.5 : 0)
        }
        .buttonStyle(.plain)
    }
}
