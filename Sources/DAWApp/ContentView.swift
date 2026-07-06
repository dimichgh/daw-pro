import SwiftUI
import DAWCore
import DAWEngine
import DAWAppKit

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    /// Selection (the open piano-roll clip) lives on AppModel, not local @State,
    /// so the `debug.captureUI` render shares it with the live window.
    @Environment(AppModel.self) private var model
    var engine: AudioEngine
    var controlPort: UInt16

    /// The clip whose piano roll is open (nil = closed). Only MIDI clips open it.
    /// Hoisted onto AppModel — see `model` above.
    private var selectedClipID: UUID? {
        get { model.selectedClipID }
        nonmutating set { model.selectedClipID = newValue }
    }

    /// Dev affordance: with `DAW_DEBUG_OPEN_PIANOROLL=1`, the piano roll auto-
    /// opens on the first MIDI clip whenever one appears and nothing is selected.
    /// Lets UI verification reach the editor without a click (a MIDI clip added
    /// over the control port pops the panel open). Off by default; never a hack
    /// in normal use.
    private static let debugOpenPianoRoll =
        ProcessInfo.processInfo.environment["DAW_DEBUG_OPEN_PIANOROLL"] == "1"

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                header

                switch model.workspaceMode {
                case .arrange:
                    arrangeWorkspace(geo)
                case .mix:
                    MixerView()
                        .frame(maxHeight: .infinity)
                }

                TransportBar(engine: engine)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(DAWTheme.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 640)
        // Window title tracks the session; " — Edited" marks unsaved changes.
        .navigationTitle(store.projectName + (store.isDirty ? " — Edited" : ""))
        .onAppear(perform: maybeAutoOpen)
        .onChange(of: firstMIDIClipID) { _, _ in maybeAutoOpen() }
        // Any clip stretch/pitch/formant change (from a drag OR the control port)
        // kicks the engine-status poll, so the timeline shimmers a clip while its
        // offline stretch render is pending and clears when it lands (M5 ii-e).
        .onChange(of: stretchSignature) { _, _ in model.noteStretchEdit() }
    }

    /// Hash of every clip's stretch parameters — changes exactly when a stretch
    /// edit lands, driving the render-status poll (`.onChange` above).
    private var stretchSignature: Int {
        var hasher = Hasher()
        for track in store.tracks {
            for clip in track.clips {
                hasher.combine(clip.id)
                hasher.combine(clip.stretchRatio)
                hasher.combine(clip.pitchShiftSemitones)
                hasher.combine(clip.formantPreserve)
            }
        }
        return hasher.finalize()
    }

    /// The Arrange surface: track list + timeline, with the piano roll docked
    /// below when a MIDI clip is open. Extracted so `body` can switch it against
    /// the Mix console without duplicating the header/transport chrome.
    @ViewBuilder
    private func arrangeWorkspace(_ geo: GeometryProxy) -> some View {
        arrangeToolbar
        HStack(spacing: 10) {
            TrackListView()
                .frame(width: 260)
            TimelineLanesView(
                tracks: store.tracks,
                positionBeats: store.transport.positionBeats,
                beatsPerBar: store.transport.timeSignature.beatsPerBar,
                selectedClipID: selectedClipID,
                onSelectClip: selectClip,
                expandedTrackIDs: model.expandedAutomationTrackIDs,
                selectedLaneByTrack: model.automationLaneSelection,
                onCommitPoints: { trackID, laneID, points in
                    _ = try? store.setAutomationPoints(trackID: trackID, laneID: laneID, points: points)
                },
                snap: model.clipSnap,
                secondsPerBeat: 60.0 / store.transport.tempoBPM,
                waveformStore: model.waveformStore,
                onMoveClip: { trackID, clip, toStart in
                    _ = try? store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: toStart)
                },
                onTrimClip: { trackID, clip, newStart, newLength in
                    _ = try? store.trimClip(trackId: trackID, clipId: clip.id,
                                            newStartBeat: newStart, newLengthBeats: newLength)
                },
                onSplitClip: { trackID, clip, atBeat in
                    _ = try? store.splitClip(trackId: trackID, clipId: clip.id, atBeat: atBeat)
                },
                onSetClipFades: { trackID, clip, fadeIn, fadeOut, inCurve, outCurve in
                    _ = try? store.setClipFades(trackId: trackID, clipId: clip.id,
                                                fadeInBeats: fadeIn, fadeOutBeats: fadeOut,
                                                fadeInCurve: inCurve, fadeOutCurve: outCurve)
                },
                onSetClipGain: { trackID, clip, gainDb in
                    _ = try? store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: gainDb)
                },
                onStretchClip: { trackID, clip, toLength in
                    _ = try? store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: toLength)
                },
                stretchStatus: { clip in model.stretchStatus(for: clip.id) },
                expandedTakeTrackIDs: model.expandedTakeTrackIDs,
                onSetTakeComp: { trackID, groupID, segments in
                    _ = try? store.setCompSegments(trackId: trackID, groupId: groupID, segments: segments)
                },
                onSelectTake: { trackID, groupID, laneID in
                    _ = try? store.selectTake(trackId: trackID, groupId: groupID, laneId: laneID)
                },
                onFlattenTakeGroup: { trackID, groupID in
                    _ = try? store.flattenTakeGroup(trackId: trackID, groupId: groupID)
                },
                onRemoveTakeLane: { trackID, groupID, laneID in
                    _ = try? store.removeTakeLane(trackId: trackID, groupId: groupID, laneId: laneID)
                }
            )
        }
        .frame(maxHeight: .infinity)

        if let clip = selectedMIDIClip {
            PianoRollView(
                clip: clip,
                beatsPerBar: store.transport.timeSignature.beatsPerBar,
                onCommit: { notes in _ = try? store.setClipNotes(clipID: clip.id, notes: notes) },
                onClose: { selectedClipID = nil }
            )
            .id(clip.id)
            .frame(height: geo.size.height * 0.45)
        }
    }

    /// A tap selects any clip (brightening it and revealing its gain readout);
    /// only a MIDI clip additionally opens the piano roll (`selectedMIDIClip`
    /// filters audio out, so the panel stays closed for audio selections).
    private func selectClip(_ clip: Clip) {
        selectedClipID = clip.id
    }

    /// Arrange-header strip: label + the grid-snap picker (right-aligned), styled
    /// like the input-device / piano-roll snap chips (docs/DESIGN-LANGUAGE.md).
    private var arrangeToolbar: some View {
        HStack(spacing: 8) {
            Text("ARRANGE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            snapPicker
        }
        .padding(.horizontal, 4)
    }

    /// Themed grid-snap menu: Off / Bar / Beat / 1/2 / 1/4. Bar follows the meter.
    private var snapPicker: some View {
        Menu {
            ForEach(ClipSnap.allCases, id: \.self) { resolution in
                Button {
                    model.clipSnap = resolution
                } label: {
                    if model.clipSnap == resolution {
                        Label(resolution.label, systemImage: "checkmark")
                    } else {
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text("SNAP: \(model.clipSnap.label)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1)
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Grid snap for clip move, trim, and split")
    }

    /// The open clip resolved against the live store, or nil when it's gone or
    /// isn't MIDI (which auto-closes the panel).
    private var selectedMIDIClip: Clip? {
        guard let id = selectedClipID else { return nil }
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }), clip.isMIDI {
                return clip
            }
        }
        return nil
    }

    /// First MIDI clip in track/clip order, for the debug auto-open.
    private var firstMIDIClipID: UUID? {
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.isMIDI }) { return clip.id }
        }
        return nil
    }

    private func maybeAutoOpen() {
        guard Self.debugOpenPianoRoll, selectedClipID == nil, let id = firstMIDIClipID else { return }
        selectedClipID = id
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("DAW PRO")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(store.projectName)
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textDim)

            Spacer()

            WorkspaceToggle(mode: model.workspaceMode) { model.workspaceMode = $0 }

            Spacer()

            inputDevicePicker

            HStack(spacing: 5) {
                Circle()
                    .fill(DAWTheme.ai)
                    .frame(width: 6, height: 6)
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.8)
                Text("MCP \(String(controlPort))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .help("AI control surface listening on ws://127.0.0.1:\(String(controlPort))")
        }
        .padding(.horizontal, 4)
    }

    /// Compact recording-input selector chip: shows the pinned device (or
    /// "Default" when following the system default) and opens the live device
    /// list. Selection applies to the NEXT take — switching mid-take is
    /// refused by the store, hence the quiet try?.
    private var inputDevicePicker: some View {
        Menu {
            Button {
                try? store.selectInputDevice(uid: nil)
            } label: {
                if store.selectedInputDeviceUID == nil {
                    Label("System Default", systemImage: "checkmark")
                } else {
                    Text("System Default")
                }
            }
            Divider()
            ForEach(store.listInputDevices()) { device in
                Button {
                    try? store.selectInputDevice(uid: device.uid)
                } label: {
                    if store.selectedInputDeviceUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Text("IN: \(selectedInputDeviceName)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1)
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording input device — takes effect on the next take")
    }

    /// Chip label: the pinned device's current name, or "Default" when
    /// following the system default (or the pinned device vanished).
    private var selectedInputDeviceName: String {
        guard let uid = store.selectedInputDeviceUID else { return "Default" }
        return store.listInputDevices().first { $0.uid == uid }?.name ?? "Default"
    }
}
