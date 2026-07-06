import SwiftUI
import DAWCore
import DAWEngine

struct TransportBar: View {
    @Environment(ProjectStore.self) private var store
    var engine: AudioEngine

    var body: some View {
        HStack(spacing: 20) {
            transportButtons

            Divider().frame(height: 36).overlay(DAWTheme.hairline)

            DigitalReadout(
                label: "Position",
                value: store.transport.barsBeatsDisplay,
                color: DAWTheme.playback,
                valueSize: 24
            )
            .frame(minWidth: 76, alignment: .leading)

            DigitalReadout(
                label: "Time",
                value: store.transport.clockDisplay,
                color: DAWTheme.playback
            )
            .frame(minWidth: 104, alignment: .leading)

            tempoCluster

            Spacer()

            testToneButton

            masterCluster
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

            TransportButton(
                systemName: store.transport.isPlaying ? "pause.fill" : "play.fill",
                isActive: store.transport.isPlaying,
                activeColor: DAWTheme.playback
            ) {
                store.transport.isPlaying ? store.stop() : store.play()
            }
            .help(store.transport.isPlaying ? "Pause" : "Play")

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

            loopChip

            punchChip

            clickChip
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
