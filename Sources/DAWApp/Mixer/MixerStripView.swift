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
                MixerInsertsSection(
                    store: store,
                    trackID: track.id,
                    effects: track.effects,
                    onAddAudioUnit: { model.openEffectPicker(trackID: track.id) },
                    onOpenWindow: { effectID in
                        model.openPluginWindow(trackID: track.id, effectID: effectID)
                    }
                )
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
            // m13-c: refused mid-recording (transportBusy) — safe no-op here.
            Button("Remove Track", role: .destructive) { _ = try? store.removeTrack(id: track.id) }
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

/// The inserts section shared by channel/bus strips and the master strip
/// (m13-d, design §6): a section label, the "+" add-menu, and one `InsertRow`
/// per effect — generalized over its target by `trackID: UUID?` (nil = the
/// MASTER chain). Every action drives the matching `ProjectStore` method —
/// `addEffect`/`removeEffect`/`setEffectBypassed` for a track/bus, the
/// `addMasterEffect`/`removeMasterEffect`/`setMasterEffectBypassed` twins for
/// master — exactly the methods the `fx.*` wire verbs call (UI == wire).
/// `addableEffectKinds` is already the built-in set = exactly what the master
/// chain accepts (built-ins only, v1), so the menu needs no per-target filter;
/// the master target opens no plugin window (built-ins have in-app editors).
struct MixerInsertsSection: View {
    var store: ProjectStore
    /// nil = the project master chain; non-nil = a track/bus by id.
    var trackID: UUID?
    var effects: [EffectDescriptor]
    /// Opens the AU-effect picker modal (m13-g, audit F6) — supplied by a track/bus
    /// host only, so the add-menu grows an "Audio Units…" item there. nil on the
    /// MASTER chain (built-ins only in v1, `masterChainBuiltInOnly`): hiding the
    /// item is the honest UI — no offer-then-error.
    var onAddAudioUnit: (() -> Void)?
    /// Opens an AU insert's plugin window (M3 vi-b) — supplied by a track/bus
    /// host only; nil on master (built-ins only).
    var onOpenWindow: ((UUID) -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                StripSectionLabel(text: "Inserts")
                addMenu
            }
            if effects.isEmpty {
                Text("No inserts")
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                ForEach(effects) { effect in
                    InsertRow(
                        store: store,
                        trackID: trackID,
                        effect: effect,
                        onToggleBypass: { toggleBypass(effect) },
                        onRemove: { remove(effect) },
                        // AU inserts get one open-window button (M3 vi-b); built-in
                        // effects (nil) have first-class in-app editors instead, and
                        // the master chain never hosts AUs so it stays nil there.
                        onOpenWindow: (trackID != nil && effect.kind == .audioUnit)
                            ? { onOpenWindow?(effect.id) }
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
                    add(kind)
                }
            }
            // Audio Units item (m13-g, audit F6): opens the searchable AU-effect
            // picker modal. Track/bus chains ONLY — the master chain is built-ins-
            // only in v1 (`masterChainBuiltInOnly`), so `onAddAudioUnit` is nil there
            // and the item is HIDDEN rather than offered-then-errored. Pro-only by
            // construction (this whole section renders only in Pro). The picker
            // drives the SAME `store.addEffect(kind:.audioUnit)` the wire's
            // `fx.add kind:"audioUnit"` uses.
            if let onAddAudioUnit {
                Divider()
                Button("Audio Units…", action: onAddAudioUnit)
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

    private func add(_ kind: EffectDescriptor.Kind) {
        if let trackID {
            _ = try? store.addEffect(toTrack: trackID, kind: kind)
        } else {
            _ = try? store.addMasterEffect(kind: kind)
        }
    }

    private func toggleBypass(_ effect: EffectDescriptor) {
        if let trackID {
            try? store.setEffectBypassed(trackID: trackID, effectID: effect.id,
                                         bypassed: !effect.isBypassed)
        } else {
            try? store.setMasterEffectBypassed(effectID: effect.id, bypassed: !effect.isBypassed)
        }
    }

    private func remove(_ effect: EffectDescriptor) {
        if let trackID {
            try? store.removeEffect(trackID: trackID, effectID: effect.id)
        } else {
            try? store.removeMasterEffect(effectID: effect.id)
        }
    }
}

/// The master strip: accent-bordered and wider, pinned at the right of the
/// console. Volume fader + stereo output meter + digital dB readout, and — in
/// Pro (m13-d) — the master INSERT chain: effects on the whole mix, post-fader
/// (the last stop before the speakers), built-ins only in v1. Simple hides the
/// section (the density-honesty rule), leaving the fader a longer throw.
struct MixerMasterStrip: View {
    @Environment(ProjectStore.self) private var store
    /// The mixer console's shared density store (`MixerView.panelID`) — read so
    /// the master strip reveals its inserts only in Pro, exactly like the
    /// channel strips.
    var densityStore: PanelDensityStore

    /// Pro density reveals the master insert chain (Simple: fader + meters only).
    private var isPro: Bool { densityStore.density(forPanel: MixerView.panelID) == .pro }

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
            // Pro-only master insert chain (built-ins only, no plugin windows).
            if isPro {
                MixerInsertsSection(
                    store: store,
                    trackID: nil,
                    effects: store.masterEffects,
                    onOpenWindow: nil
                )
                .explainable(.mixerMasterInserts)
                Divider().overlay(DAWTheme.playback.opacity(0.25))
                // Pro-only master VOLUME automation (m15-c): a fit-to-width fade
                // editor for the whole mix. Simple hides it, like the inserts above.
                MasterAutomationSection()
                Divider().overlay(DAWTheme.playback.opacity(0.25))
            }
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

/// The master strip's VOLUME AUTOMATION section (m15-c, Pro only): a fit-to-width
/// breakpoint editor for the whole-mix master fade. It mirrors a track's arrange
/// automation lane — the SAME `AutomationLaneEditor` / `AutomationGeometry` /
/// `AutomationEdit` machinery and the same click-to-add / drag-to-move /
/// double-click-to-delete interactions — but homed on the master STRIP, the
/// master's only place in the app (it has no arrange row or sidebar header, so its
/// lane lives with its owner, exactly as a track's lane lives on the track's arrange
/// row). Simple density hides the whole section (the density-honesty rule, like the
/// master inserts). Every edit routes through the store's master-automation methods —
/// the SAME ones the `automation.* {trackId:"master"}` wire verbs call, so a lane
/// edited here is byte-identical to one edited by an agent (UI == wire by construction).
struct MasterAutomationSection: View {
    @Environment(ProjectStore.self) private var store

    /// Compact lane height (vs the arrange's 64) — the strip is narrow, and a
    /// master fade is a handful of points, so it reads fine shorter.
    private static let laneHeight: CGFloat = 58

    /// The master VOLUME lane, or nil when the mix has none yet (→ the create
    /// button). v1 keeps at most one master lane, so this is the whole surface.
    private var lane: AutomationLane? {
        AutomationLaneSelection.masterVolumeLane(in: store.masterAutomation)
    }

    /// The whole-song beat span the overview fits into its width. A master fade
    /// lands on the song, so the lane shows the WHOLE song at a glance (fit-to-width,
    /// no nested scroll). Measured from the mix's last clip end, floored at 16 so an
    /// empty/short session still reads. Clip content ONLY (never the lane's own
    /// points), so the fit stays STABLE while you drag a breakpoint — the scale never
    /// rescales under the cursor.
    private var spanBeats: Double {
        let lastClipEnd = store.tracks.flatMap(\.clips)
            .map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        return max(lastClipEnd, 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let lane {
                editor(lane)
            } else {
                createButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .explainable(.masterAutomation)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // "AUTOMATION" verbatim from the track sidebar's AutomationTrackControls
            // (the master lane is volume-only, so no target chips). In the narrow
            // master strip the ON/OFF + trash controls get FIRST claim on the width —
            // the label shrinks a hair (minimumScaleFactor) rather than the toggle
            // truncating, so "ON" always reads in full.
            Text("AUTOMATION")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(0)
            Spacer(minLength: 4)
            if let lane {
                enableToggle(lane).layoutPriority(1)
                removeButton(lane).layoutPriority(1)
            }
        }
    }

    /// Shown when no master lane exists — creates the volume lane (empty + inert
    /// until points land), which flips this section into the editor.
    private var createButton: some View {
        Button {
            _ = try? store.addMasterAutomationLane(target: .volume)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .bold))
                Text("Automate Volume")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(DAWTheme.playback)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(DAWTheme.playback.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.playback.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Draw a master volume fade or level ride across the whole mix")
    }

    /// The fit-to-width lane editor: the shared `AutomationLaneEditor` scaled so the
    /// whole `spanBeats` fills the strip width (GeometryReader → pixelsPerBeat).
    private func editor(_ lane: AutomationLane) -> some View {
        GeometryReader { geo in
            AutomationLaneEditor(
                lane: lane,
                param: .volume,
                geometry: AutomationGeometry(
                    pixelsPerBeat: max(1, geo.size.width / CGFloat(spanBeats)),
                    laneHeight: Self.laneHeight,
                    range: AutomationParam.volume.range),
                contentWidth: geo.size.width,
                onCommit: { points in
                    _ = try? store.setMasterAutomationPoints(laneID: lane.id, points: points)
                }
            )
            // Re-seed the editor's draft if the lane identity changes (create/remove).
            .id(lane.id)
        }
        .frame(height: Self.laneHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// Read/manual toggle — green "ON" when the drawn fade drives the master, dim
    /// "OFF" when the manual master fader is back in charge (the track lane idiom).
    private func enableToggle(_ lane: AutomationLane) -> some View {
        Button {
            _ = try? store.setMasterAutomationLaneEnabled(laneID: lane.id, !lane.isEnabled)
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
        .help(lane.isEnabled ? "Automation on — the drawn fade drives the master volume"
                             : "Automation off — the master fader is manual")
    }

    private func removeButton(_ lane: AutomationLane) -> some View {
        Button {
            _ = try? store.removeMasterAutomationLane(laneID: lane.id)
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
        .help("Delete the master volume automation lane")
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
