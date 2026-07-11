import SwiftUI
import DAWCore
import DAWEngine
import DAWAppKit

struct TransportBar: View {
    @Environment(ProjectStore.self) private var store
    /// The app model, for the vibe meter's seed override (`debug.vibeSeed`). The
    /// meter reads `appModel.vibeSeed ?? store.masterAnalysis()` — the seeded snapshot
    /// preferred over the live engine poll for captures/E2E.
    @Environment(AppModel.self) private var appModel
    var engine: AudioEngine
    /// The transport bar's shared density store (docs/DESIGN-LANGUAGE.md
    /// "Panels"). The whole bar is ONE panel (`TransportBar.panelID`): Simple
    /// shows transport + LOOP/CLICK + Position/Time + tempo + master; Pro
    /// additionally reveals PUNCH (the advanced record window) and the test-tone
    /// verify affordance. A plain value input — a preview can pass a
    /// `PanelDensityStore()` with an in-memory backing.
    var densityStore: PanelDensityStore

    /// Stable density key for the transport bar — one panel, so the chip and the
    /// gated PUNCH/test-tone controls share this ID.
    static let panelID = "transport"

    /// Pro density reveals PUNCH + the test-tone verify button; every other
    /// control stays in both modes. Read per-bar (`Self.panelID`).
    private var isPro: Bool { densityStore.density(forPanel: Self.panelID) == .pro }

    var body: some View {
        HStack(spacing: 20) {
            // Fixed leading width so PUNCH hiding closes the chip row up (LOOP +
            // CLICK go adjacent) WITHOUT moving the Position/Time readouts — the
            // bar's visual anchor. The freed room reads as breathing room before
            // the section Divider, never a PUNCH-shaped hole in the row.
            transportButtons
                .frame(width: 340, alignment: .leading)

            Divider().frame(height: 36).overlay(DAWTheme.hairline)

            DigitalReadout(
                label: "Position",
                value: store.transport.barsBeatsDisplay,
                color: DAWTheme.playback,
                valueSize: 24
            )
            .frame(minWidth: 76, alignment: .leading)
            .explainable(.transportPosition)

            DigitalReadout(
                label: "Time",
                value: store.transport.clockDisplay,
                color: DAWTheme.playback
            )
            .frame(minWidth: 104, alignment: .leading)
            .explainable(.transportTime)

            tempoCluster
                .explainable(.transportTempo)

            Spacer()

            // EXPORT: bounce the whole mix to a file. A core beginner action, so it
            // shows in BOTH densities. Right-region, past the Spacer — it never
            // touches the 340 pt readout anchor on the left (Position/Time stay put).
            exportButton
                .explainable(.transportExport)

            // Pro-only diagnostic. Right-packed, so hiding it only grows the
            // Spacer — the master cluster and the mode chip stay put.
            if isPro {
                testToneButton
                    .explainable(.transportTestTone)
            }

            // The session vibe meter — the signature glowing instrument (vm-b). It's
            // read-only STATUS chrome, so it shows in BOTH Simple and Pro, sitting just
            // left of the master cluster. Reads the seed override, else the live poll.
            VibeMeterView(snapshot: { appModel.vibeSeed ?? store.masterAnalysis() })
                .frame(width: 74, height: 44)
                .explainable(.vibeMeter)

            masterCluster
                .explainable(.transportMasterFader)

            // The bar's mode chip, pinned far-right (past the master cluster) so
            // it never reads as part of the record cluster and its presence never
            // reflows Position/Time.
            SimpleProToggle(
                store: densityStore,
                panelID: Self.panelID,
                help: "Simple: play, loop, click, tempo. Pro: punch recording, test tone."
            )
            .explainable(.panelDensity)   // shared density id (ex-b) — same card on all four panels
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassPanel()
    }

    private var transportButtons: some View {
        HStack(spacing: 10) {
            TransportButton(
                systemName: "backward.end.fill",
                isActive: false,
                activeColor: DAWTheme.playback
            ) {
                try? store.returnToZero()
            }
            .disabled(store.transport.isRecording)  // seeking is refused mid-take
            .help("Return to start")
            .explainable(.transportReturnToZero)

            TransportButton(
                systemName: store.transport.isPlaying ? "pause.fill" : "play.fill",
                isActive: store.transport.isPlaying,
                activeColor: DAWTheme.playback
            ) {
                store.transport.isPlaying ? store.stop() : store.play()
            }
            .help(store.transport.isPlaying ? "Pause" : "Play")
            .explainable(.transportPlay)

            TransportButton(
                systemName: "record.circle",
                isActive: store.transport.isRecording,
                activeColor: DAWTheme.record
            ) {
                if store.transport.isRecording {
                    store.stop()
                } else {
                    try? store.record()
                }
            }
            .disabled(!store.transport.isRecording
                      && !store.hasArmedAudioTracks && !store.hasArmedInstrumentTracks)
            .help(recordHelp)
            .explainable(.transportRecord)

            loopChip
                .explainable(.transportLoop)

            // Pro-only: PUNCH is an advanced record window. In Simple the chip
            // row closes up naturally (LOOP + CLICK go adjacent) — no placeholder.
            if isPro {
                punchChip
                    .explainable(.transportPunch)
            }

            clickChip
                .explainable(.transportClick)
        }
    }

    /// Why record is (un)available, surfaced right on the button.
    private var recordHelp: String {
        if store.transport.isRecording { return "Stop recording" }
        if let error = store.lastRecordingError { return error }
        return store.hasArmedAudioTracks || store.hasArmedInstrumentTracks
            ? "Record onto armed tracks"
            : "Record — arm a track (R) first"
    }

    /// Toggles looping. Range editing arrives with the arrange view; for now the
    /// chip flips `isLoopEnabled` and keeps the current region.
    private var loopChip: some View {
        let isOn = store.transport.isLoopEnabled
        return Button {
            try? store.setLoop(enabled: !store.transport.isLoopEnabled)
        } label: {
            Text("LOOP")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                .frame(height: 22)
                .padding(.horizontal, 9)
                .background(isOn ? DAWTheme.playback.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(
                        isOn ? DAWTheme.playback.opacity(0.6) : DAWTheme.hairline,
                        lineWidth: 1
                    )
                )
                .glow(DAWTheme.playback, radius: 5, intensity: isOn ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Looping on" : "Loop playback")
    }

    /// Toggles the punch recording window. Range editing arrives with the
    /// arrange view; for now the chip flips `isPunchEnabled` and keeps the
    /// current window. Record-amber: punch shapes the next take, not playback.
    private var punchChip: some View {
        let isOn = store.transport.isPunchEnabled
        return Button {
            try? store.setPunch(enabled: !store.transport.isPunchEnabled)
        } label: {
            Text("PUNCH")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(isOn ? DAWTheme.record : DAWTheme.textDim)
                .frame(height: 22)
                .padding(.horizontal, 9)
                .background(isOn ? DAWTheme.record.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(
                        isOn ? DAWTheme.record.opacity(0.6) : DAWTheme.hairline,
                        lineWidth: 1
                    )
                )
                .glow(DAWTheme.record, radius: 5, intensity: isOn ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .disabled(store.transport.isRecording)  // punch changes are refused mid-take
        .help("Punch recording window")
    }

    /// Toggles the metronome click. Signal green: the click is a healthy
    /// reference signal, not a transport mode. Count-in has no UI yet — it is
    /// set via the control protocol / MCP (transport.setMetronome countInBars)
    /// until the record cluster grows a count-in selector.
    private var clickChip: some View {
        let isOn = store.transport.isMetronomeEnabled
        return Button {
            try? store.setMetronome(enabled: !store.transport.isMetronomeEnabled)
        } label: {
            Text("CLICK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(isOn ? DAWTheme.signal : DAWTheme.textDim)
                .frame(height: 22)
                .padding(.horizontal, 9)
                .background(isOn ? DAWTheme.signal.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(
                        isOn ? DAWTheme.signal.opacity(0.6) : DAWTheme.hairline,
                        lineWidth: 1
                    )
                )
                .glow(DAWTheme.signal, radius: 5, intensity: isOn ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .disabled(store.transport.isRecording)  // metronome changes are refused mid-take
        .help("Metronome click")
    }

    private var tempoCluster: some View {
        HStack(spacing: 8) {
            DigitalReadout(
                label: "Tempo",
                value: String(format: "%.1f", store.transport.tempoBPM),
                color: DAWTheme.textPrimary
            )
            VStack(spacing: 3) {
                TempoNudgeButton(label: "+") { try? store.setTempo(store.transport.tempoBPM + 1) }
                TempoNudgeButton(label: "−") { try? store.setTempo(store.transport.tempoBPM - 1) }
            }
            .disabled(store.transport.isRecording)  // tempo changes are refused mid-take
        }
    }

    /// Master fader beside the master meter: set the mix bus gain, watch it.
    private var masterCluster: some View {
        HStack(spacing: 6) {
            MasterVolumeFader(volume: store.masterVolume) { store.setMasterVolume($0) }
                .frame(width: 10, height: 44)
                .help("Master volume — drag to set, double-click for unity")

            SegmentMeter(meter: store.masterMeter)
                .frame(width: 10, height: 44)
        }
    }

    /// Compact EXPORT affordance — neutral action chrome (Rule 3: an action earns no
    /// accent), textDim on a raised chip with a hairline. Click → NSSavePanel →
    /// `store.renderBounce` (via `appModel.exportSong`); completion flows through the
    /// store's `renderCompletedCount`, so the onboarding tour's export step advances
    /// on the same one path.
    private var exportButton: some View {
        Button { appModel.exportSong() } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("EXPORT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Export your song to an audio file")
    }

    private var testToneButton: some View {
        TransportButton(
            systemName: "tuningfork",
            isActive: engine.isTonePlaying,
            activeColor: DAWTheme.signal
        ) {
            if engine.isTonePlaying {
                engine.stopTestTone()
            } else {
                try? engine.startTestTone()
            }
        }
        .help("Test tone (verifies audio output)")
    }
}

struct TransportButton: View {
    var systemName: String
    var isActive: Bool
    var activeColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : DAWTheme.textPrimary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(isActive ? activeColor.opacity(0.15) : DAWTheme.panelRaised)
                )
                .overlay(
                    Circle().stroke(
                        isActive ? activeColor.opacity(0.7) : DAWTheme.hairline,
                        lineWidth: 1
                    )
                )
                .glow(activeColor, radius: 8, intensity: isActive ? 0.7 : 0)
        }
        .buttonStyle(.plain)
    }
}

struct TempoNudgeButton: View {
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 18, height: 15)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}
