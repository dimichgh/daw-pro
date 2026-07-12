import SwiftUI
import DAWCore
import DAWAppKit

/// Built-in inserts a user can add from the strip's "+" menu. Hosted Audio
/// Units need a component picker (not in this view's scope) and are added over
/// the control plane, so they're excluded here.
private let addableEffectKinds: [EffectDescriptor.Kind] =
    [.gain, .eq, .compressor, .limiter, .reverb, .delay, .saturator, .gate, .chorus]

/// One channel or bus strip. Channels (audio/instrument) show the full anatomy;
/// bus strips drop arm, sends, and the output picker (buses always sum to
/// master). Every control drives `ProjectStore` directly — undo/coalescing is
/// handled store-side.
struct MixerChannelStrip: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    var track: Track
    /// The mixer console's shared density store (docs/DESIGN-LANGUAGE.md
    /// "Panels"). The whole console is ONE panel (`MixerView.panelID`): Simple
    /// shows the name/kind badge, pan, the fader/meter/dB, and Mute/Solo/Arm; Pro
    /// additionally reveals the inserts, sends, and output-routing sections. A
    /// plain value input — a preview can pass a `PanelDensityStore()` with an
    /// in-memory backing.
    var densityStore: PanelDensityStore

    private var isBus: Bool { track.kind == .bus }
    /// True when this track hosts an Audio Unit instrument — the only instrument
    /// kind with a plugin window (built-ins have first-class in-app panels).
    private var hostsAUInstrument: Bool {
        track.kind == .instrument && (track.instrument ?? .default).kind == .audioUnit
    }
    private var meter: MeterFrame { store.trackMeters[track.id] ?? .silence }
    private var accent: Color { track.isAIGenerated ? DAWTheme.ai : DAWTheme.hairline }
    /// Pro density reveals the signal-flow sections (inserts / sends / output).
    /// Density is read per-console (`MixerView.panelID`), never per-strip.
    private var isPro: Bool { densityStore.density(forPanel: MixerView.panelID) == .pro }

    var body: some View {
        VStack(spacing: 8) {
            header
            // Pro-only signal-flow sections. In Simple they hide WHOLE and the
            // freed vertical space flows into `faderAndMeter` (maxHeight: .infinity),
            // giving beginners a longer fader throw / finer level control.
            if isPro {
                insertsSection
                    .explainable(.mixerInserts)
                if !isBus {
                    sendsSection
                        .explainable(.mixerSends)
                    outputSection
                        .explainable(.mixerOutput)
                }
            }
            // Header/controls separator — present in both modes so the strip reads
            // as designed (not amputated) when the Pro sections are hidden.
            Divider().overlay(DAWTheme.hairline)
            panSection
                .explainable(.mixerPan)
            faderAndMeter
                .explainable(.mixerFader)
            controlButtons
        }
        .padding(10)
        .frame(width: 132)
        .frame(maxHeight: .infinity)
        .background(isBus ? DAWTheme.panel.opacity(0.55) : DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(track.isAIGenerated ? DAWTheme.ai.opacity(0.4) : DAWTheme.hairline, lineWidth: 1)
        )
        .contextMenu {
            Button("Remove Track", role: .destructive) { store.removeTrack(id: track.id) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(track.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(track.isAIGenerated ? DAWTheme.ai : DAWTheme.textPrimary)
                    .lineLimit(1)
                if track.isAIGenerated {
                    Circle().fill(DAWTheme.ai).frame(width: 5, height: 5)
                        .glow(DAWTheme.ai, radius: 4, intensity: 0.8)
                        .help("AI-generated")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                KindBadge(kind: track.kind)
                    .explainable(.mixerKindBadge)
                Spacer(minLength: 0)
                // The AU-instrument plugin window (M3 vi-b) — one button. NEVER
                // shown for a soundBank instrument (LAW L7): AUSampler's generic
                // view isn't user-meaningful — the picker IS its editor. The guard
                // is `hostsAUInstrument` == `.kind == .audioUnit`, so soundBank
                // tracks never reach it.
                if hostsAUInstrument {
                    PluginWindowButton { model.openPluginWindow(trackID: track.id) }
                        .help("Open the instrument plugin window")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The instrument chip (m10-n-3): the current sound + the picker opener,
            // for instrument tracks only. Full variant (the strip has room).
            if track.kind == .instrument {
                InstrumentChip(
                    descriptor: track.instrument,
                    status: store.audioUnitStatus(forTrack: track.id),
                    compact: false,
                    onOpen: { model.openInstrumentPicker(trackID: track.id) }
                )
            }
        }
    }

    // MARK: Inserts

    private var insertsSection: some View {
        VStack(spacing: 4) {
            HStack {
                StripSectionLabel(text: "Inserts")
                addMenu
            }
            if track.effects.isEmpty {
                Text("No inserts")
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                ForEach(track.effects) { effect in
                    InsertRow(
                        effect: effect,
                        onToggleBypass: {
                            try? store.setEffectBypassed(trackID: track.id, effectID: effect.id,
                                                         bypassed: !effect.isBypassed)
                        },
                        onRemove: { try? store.removeEffect(trackID: track.id, effectID: effect.id) },
                        // AU inserts get one open-window button (M3 vi-b); built-in
                        // effects (nil) have first-class in-app editors instead.
                        onOpenWindow: effect.kind == .audioUnit
                            ? { model.openPluginWindow(trackID: track.id, effectID: effect.id) }
                            : nil
                    )
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(addableEffectKinds, id: \.self) { kind in
                Button(MixerFormat.effectDisplayName(EffectDescriptor(kind: kind))) {
                    _ = try? store.addEffect(toTrack: track.id, kind: kind)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textPrimary)
                .frame(width: 16, height: 16)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add an insert effect")
    }

    // MARK: Sends

    private var sendsSection: some View {
        VStack(spacing: 4) {
            HStack {
                StripSectionLabel(text: "Sends")
                sendAddMenu
            }
            if track.sends.isEmpty {
                Text("No sends")
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                ForEach(track.sends) { send in
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(MixerLayout.sendDestinationName(send, in: store.tracks))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(DAWTheme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(MixerFormat.dbString(forGain: send.level))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(DAWTheme.textDim)
                        }
                        SendMiniFader(
                            level: send.level,
                            onChange: { _ = try? store.setSendLevel(trackID: track.id, sendID: send.id, level: $0) }
                        )
                        .frame(height: 7)
                    }
                    .contextMenu {
                        Button("Remove Send", role: .destructive) {
                            try? store.removeSend(trackID: track.id, sendID: send.id)
                        }
                    }
                }
            }
        }
    }

    private var sendAddMenu: some View {
        let buses = MixerLayout.availableSendBuses(for: track, in: store.tracks)
        return Menu {
            if buses.isEmpty {
                Text("No buses available")
            } else {
                ForEach(buses) { bus in
                    Button(bus.name) { _ = try? store.addSend(toTrack: track.id, busID: bus.id) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(buses.isEmpty ? DAWTheme.textDim : DAWTheme.textPrimary)
                .frame(width: 16, height: 16)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(buses.isEmpty)
        .help("Send this track to a bus")
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(spacing: 3) {
            StripSectionLabel(text: "Output")
            Menu {
                ForEach(MixerLayout.outputOptions(in: store.tracks)) { option in
                    Button {
                        try? store.setTrackOutput(id: track.id, busID: option.busID)
                    } label: {
                        if option.busID == track.outputBusID {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .bold))
                    Text(MixerLayout.outputName(for: track, in: store.tracks))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DAWTheme.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Route this track's output")
        }
    }

    // MARK: Pan

    private var panSection: some View {
        HStack(spacing: 8) {
            PanKnob(pan: track.pan, onChange: { store.setTrackPan(id: track.id, pan: $0) })
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("PAN")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
                Text(MixerFormat.panString(track.pan))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textPrimary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Fader + meter

    private var faderAndMeter: some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VerticalFader(
                    gain: track.volume,
                    onChange: { store.setTrackVolume(id: track.id, volume: $0) }
                )
                .frame(width: 34)
                SegmentMeter(meter: meter, segmentCount: 24)
                    .frame(width: 12)
            }
            .frame(maxHeight: .infinity)
            DbReadout(gain: track.volume)
        }
        .frame(maxHeight: .infinity)
        .frame(minHeight: 150)
    }

    // MARK: Mute / Solo / Arm

    private var controlButtons: some View {
        HStack(spacing: 5) {
            MixerStateButton(label: "Mute", isOn: track.isMuted, color: DAWTheme.clip) {
                store.setTrackMute(id: track.id, muted: !track.isMuted)
            }
            .explainable(.mixerMute)
            MixerStateButton(label: "Solo", isOn: track.isSoloed, color: DAWTheme.playback) {
                store.setTrackSolo(id: track.id, soloed: !track.isSoloed)
            }
            .explainable(.mixerSolo)
            if !isBus {
                MixerStateButton(label: "Arm", isOn: track.isArmed, color: DAWTheme.record, pulse: true) {
                    _ = try? store.setTrackArm(id: track.id, armed: !track.isArmed)
                }
                .explainable(.mixerArm)
            }
        }
    }
}

/// The master strip: accent-bordered and wider, pinned at the right of the
/// console. Volume fader + stereo output meter + digital dB readout. (DAWCore
/// has no master insert chain — effects are per-track — so master inserts are
/// intentionally absent; see the milestone report.)
struct MixerMasterStrip: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 5) {
                Text("MASTER")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(DAWTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Main Output")
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(DAWTheme.playback.opacity(0.25))
            HStack(alignment: .center, spacing: 10) {
                VerticalFader(
                    gain: store.masterVolume,
                    onChange: { store.setMasterVolume($0) }
                )
                .frame(width: 40)
                HStack(spacing: 3) {
                    SegmentMeter(meter: store.masterMeter, segmentCount: 28).frame(width: 13)
                    SegmentMeter(meter: store.masterMeter, segmentCount: 28).frame(width: 13)
                }
            }
            .frame(maxHeight: .infinity)
            .frame(minHeight: 180)
            .explainable(.mixerMaster)
            DbReadout(gain: store.masterVolume)
        }
        .padding(12)
        .frame(width: 156)
        .frame(maxHeight: .infinity)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.playback.opacity(0.4), lineWidth: 1.5)
        )
        .glow(DAWTheme.playback, radius: 8, intensity: 0.12)
    }
}

/// The glowing SF-Mono dB value shown under a fader.
struct DbReadout: View {
    var gain: Double
    var body: some View {
        HStack(spacing: 3) {
            Text(MixerFormat.dbString(forGain: gain))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .glow(DAWTheme.playback, radius: 4, intensity: 0.5)
            Text("dB")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
        }
        .lineLimit(1)
    }
}
