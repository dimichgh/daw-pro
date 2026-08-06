import SwiftUI
import DAWCore
import DAWAppKit

/// Built-in inserts a user can add from the strip's "+" menu. Hosted Audio
/// Units need a component picker (not in this view's scope) and are added over
/// the control plane, so they're excluded here.
/// HAND-MAINTAINED, not `Kind.allCases` — a new built-in kind is INVISIBLE in
/// the "+" menu until it is appended here (the compiler cannot catch the
/// omission).
private let addableEffectKinds: [EffectDescriptor.Kind] =
    [.gain, .eq, .compressor, .limiter, .reverb, .delay, .saturator, .gate, .chorus,
     .bassEnhancer]

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
    /// The console's shared layout store (m23-a) — read for ONE value here, the
    /// INSERTS disclosure flag. Console-wide like density (the mixer is one panel),
    /// app-sticky, never project data. A plain value input: a preview can pass a
    /// `PanelLayoutStore()` with the in-memory backing.
    var layoutStore: PanelLayoutStore

    // MARK: Reorder drag (m23-z) — owned by the CONSOLE, driven from here

    /// How far this strip is displaced while it is the one being dragged; nil on
    /// every other strip (and on all of them when no drag is in flight). One
    /// value carries both "am I lifted" and "by how much".
    var dragOffsetX: CGFloat?
    /// Pointer moved, in the strip rack's coordinate space.
    var onReorderChanged: (CGFloat) -> Void = { _ in }
    /// Pointer released, in the strip rack's coordinate space.
    var onReorderEnded: (CGFloat) -> Void = { _ in }

    private var isDragging: Bool { dragOffsetX != nil }

    private var isBus: Bool { track.kind == .bus }
    /// True when this track hosts an Audio Unit instrument — the only instrument
    /// kind with a plugin window (built-in instruments are edited in the
    /// instrument picker, which IS their editor — LAW L7; built-in insert
    /// EFFECTS open the in-window effect editor card, m17-a).
    private var hostsAUInstrument: Bool {
        track.kind == .instrument && (track.instrument ?? .default).kind == .audioUnit
    }
    private var meter: MeterFrame { store.trackMeters[track.id] ?? .silence }
    private var accent: Color { track.isAIGenerated ? DAWTheme.ai : DAWTheme.hairline }
    /// Pro density reveals the signal-flow sections (inserts / sends / output).
    /// Density is read per-console (`MixerView.panelID`), never per-strip.
    private var isPro: Bool { densityStore.density(forPanel: MixerView.panelID) == .pro }

    var body: some View {
        // The strip reads its OWN available height (m23-a) for two reasons.
        // (1) It bounds the Pro signal-flow region against `MixerStripLayout`'s
        // reserved budget, so inserts can never push the fader / dB readout /
        // Mute-Solo-Arm row out of the strip. (2) A `GeometryReader` has no
        // intrinsic minimum, so the strip stops exporting a tall minimum height to
        // the console — which is what used to shove the app header row and the
        // transport bar clean off the window at a short window with a full chain.
        GeometryReader { proxy in
            stripBody(available: proxy.size.height)
        }
        .frame(width: MixerStripLayout.channelStripWidth)
        .frame(maxHeight: .infinity)
        .background(isBus ? DAWTheme.panel.opacity(0.55) : DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isDragging
                        ? DAWTheme.playback.opacity(0.7)
                        : (track.isAIGenerated ? DAWTheme.ai.opacity(0.4) : DAWTheme.hairline),
                    lineWidth: 1)
        )
        // Picked up: the strip LIFTS off the rack — a cyan rim, a soft glow and
        // a cast shadow, all earned by the drag and gone the instant it ends
        // (Rule 3: nothing static glows). The offset follows the pointer so the
        // strip is literally the thing being moved, not a proxy for it.
        .glow(DAWTheme.playback, radius: 6, intensity: isDragging ? 0.45 : 0)
        .shadow(color: .black.opacity(isDragging ? 0.45 : 0),
                radius: isDragging ? 10 : 0, x: isDragging ? 4 : 0)
        .offset(x: dragOffsetX ?? 0)
        .contextMenu {
            // m13-c: refused mid-recording (transportBusy) — safe no-op here.
            Button("Remove Track", role: .destructive) { _ = try? store.removeTrack(id: track.id) }
        }
    }

    /// The strip's stack, laid out against the height it actually has.
    ///
    /// **The reserved cluster never yields.** Everything from the separator down —
    /// the VOL|PAN knob row, the fader + meter + dB readout, and Mute/Solo/Arm — is
    /// fixed-intrinsic apart from the fader region, which is greedy upward and only
    /// compresses to `MixerStripLayout.faderRegionFloor` (a valve, not the target).
    /// The ONE yielding element is the Pro signal-flow region.
    private func stripBody(available: CGFloat) -> some View {
        VStack(spacing: MixerStripLayout.stripSpacing) {
            header
            // Pro-only signal-flow sections. In Simple they hide WHOLE and the
            // freed vertical space flows into `faderAndMeter` (maxHeight: .infinity),
            // giving beginners a longer fader throw / finer level control.
            if isPro {
                signalFlow(room: MixerStripLayout.signalFlowRoom(available: available))
            }
            // Header/controls separator — present in both modes so the strip reads
            // as designed (not amputated) when the Pro sections are hidden.
            Divider().overlay(DAWTheme.hairline)
            knobSection
            faderAndMeter
                .explainable(.mixerFader)
            controlButtons
        }
        .padding(MixerStripLayout.channelStripHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The Pro signal-flow block (inserts · sends · output) — the strip's ONE
    /// yielding region, bounded by `room`.
    ///
    /// **The yield mechanism is an internal vertical scroller with a computed
    /// cap, sized to HUG its content until it hits that cap.** The alternative
    /// considered and rejected was a max-visible-rows cut with a "+N more"
    /// affordance: it hides rows at a count threshold rather than at the height
    /// that actually matters, so it would still clip on a short window and still
    /// hide rows needlessly on a tall one.
    ///
    /// The three modifiers are one mechanism and must be read together:
    ///
    /// * `.fixedSize(vertical:)` makes the region take its IDEAL height instead of
    ///   the height the `VStack` offers. Without it a `maxHeight` frame stretches
    ///   to whatever it is proposed, so a two-insert strip held a ~200 pt void and
    ///   the fader sat crammed at the bottom — the exact failure this item exists
    ///   to remove, reintroduced by the guard rail.
    /// * A `ScrollView`'s ideal height is its CONTENT's height, so hugging and
    ///   scrolling come from the same view: no `ViewThatFits`, no duplicated
    ///   subtree (which would also duplicate the `.explainable` anchors inside).
    /// * `.frame(maxHeight: room)` is the bound: the ideal is clamped to `room`,
    ///   and past that the content scrolls inside a region that never grows. This
    ///   is what guarantees the reserved cluster, because `room` is already
    ///   `available − reserved`.
    ///
    /// Net effect: the region is INFLEXIBLE at `min(content, room)`, so the greedy
    /// fader below takes every remaining point. Chain first up to the bound, fader
    /// throw with the rest.
    ///
    /// **The "strips hug independently" rule was REVERSED by the user — do not
    /// restore it as a regression fix.** m23-a's note here read: *"Strips therefore
    /// hug independently and their dividers do NOT line up across the console — that
    /// is deliberate: a uniform divider costs every strip the tallest strip's chain
    /// height."* That reasoning was sound and its cost was real, but it left the
    /// thing the user actually complained about untouched: inside a strip the chain
    /// still pushed the PAN row, the fader, the dB readout, the sends and the output
    /// picker DOWN — 121 pt of travel across five inserts, measured — so a control
    /// moved under the hand on every add/remove and no two strips agreed on where
    /// the fader was. Told the price, the user chose it: **the inserts ROWS now sit
    /// in a fixed 3-slot viewport** (`MixerStripLayout.insertsViewportHeight`), whose
    /// height is a function of `room` alone. `room` is identical for every strip in
    /// the console, so the block below the inserts now starts at the same Y on every
    /// strip and stays there — and a strip with one insert carries two rows of
    /// deliberate empty space, which is the trade, not a bug.
    ///
    /// SENDS and OUTPUT still hug (only the inserts block is reserved), so the
    /// output picker still moves when a SEND is added — out of scope, and unlike
    /// inserts a send is rarely added mid-mix.
    private func signalFlow(room: CGFloat) -> some View {
        ScrollView(.vertical) { signalFlowContent(room: room) }
            .scrollIndicators(.visible)
            .frame(maxHeight: max(0, room))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func signalFlowContent(room: CGFloat) -> some View {
        VStack(spacing: MixerStripLayout.stripSpacing) {
            MixerInsertsSection(
                store: store,
                trackID: track.id,
                effects: track.effects,
                onAddBuiltIn: { kind in
                    // The UI add funnel (m17-a): store add + AUTO-OPEN of the
                    // effect editor card (wire fx.add never auto-opens).
                    model.addBuiltInInsert(trackID: track.id, kind: kind)
                },
                onAddAudioUnit: { model.openEffectPicker(trackID: track.id) },
                onOpenWindow: { effectID in
                    model.openPluginWindow(trackID: track.id, effectID: effectID)
                },
                onOpenEditor: { effectID in
                    model.toggleEffectEditor(trackID: track.id, effectID: effectID)
                },
                gainReductionFor: { effectID in
                    model.gainReductionDb(trackID: track.id, effectID: effectID)
                },
                isCollapsed: layoutStore.mixerInsertsCollapsed,
                onToggleCollapsed: {
                    layoutStore.setMixerInsertsCollapsed(!layoutStore.mixerInsertsCollapsed)
                },
                // The fixed reserve. Computed from `room` and the strip CLASS —
                // NEVER from `track.effects.count`, which is exactly why no strip's
                // fader moves when an insert is added (see `signalFlow(room:)`).
                //
                // m23-ax: a BUS reserves five rows where a channel reserves three.
                // It can afford them because it draws no sends section and no output
                // picker, and it needs them because a bus is a summing point whose
                // chain is a glue chain. Channels are untouched — the user asked for
                // "master and bus", and holding the channel at 3 keeps every existing
                // assertion about it a live control on this change.
                rowsViewportHeight: MixerStripLayout.insertsViewportHeight(
                    room: room,
                    isCollapsed: layoutStore.mixerInsertsCollapsed,
                    slots: isBus ? MixerStripLayout.busInsertsReservedSlots
                                 : MixerStripLayout.insertsReservedSlots),
                onRowProbe: { model.insertLabels.record($0) }
            )
            .explainable(.mixerInserts)
            if !isBus {
                sendsSection
                    .explainable(.mixerSends)
                outputSection
                    .explainable(.mixerOutput)
            }
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
            // The NAME ROW is the reorder handle (m23-z) — not the whole header
            // (which also carries the plugin-window button and the instrument
            // chip's opener) and not the strip (which carries a context menu and
            // every fader/knob gesture). `contentShape` makes the whole row
            // grabbable rather than just the glyphs: without it the drag is
            // nearly dead in the hand while every headless test and the seam stay
            // green. A 6 pt minimum distance means a press that doesn't travel is
            // never a drag — every click the strip already has stays reachable.
            .contentShape(Rectangle())
            .gesture(reorderDrag)
            .help("Drag to reorder this strip")
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
            // ALIGNMENT SLOT (m17-f F2): every strip reserves this row's height —
            // audio/bus strips render it empty — so PAN, the fader top, and (in
            // Pro) the INSERTS header line up ACROSS the rack instead of shifting
            // up ~26 pt on every non-instrument strip (a rack whose knobs sit at
            // per-kind heights reads as misalignment, the classic console rule).
            Group {
                if track.kind == .instrument {
                    InstrumentChip(
                        descriptor: track.instrument,
                        status: store.audioUnitStatus(forTrack: track.id),
                        compact: false,
                        onOpen: { model.openInstrumentPicker(trackID: track.id) }
                    )
                } else {
                    Color.clear
                }
            }
            .frame(height: 25)
        }
    }

    /// The reorder gesture. Reports the pointer in the RACK's coordinate space
    /// (never `.local`), which is the space the strip ladder is measured in — so
    /// the landing is right at any horizontal scroll offset.
    private var reorderDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(MixerView.stripSpace))
            .onChanged { value in
                // Hold the closed hand for the whole drag, even when the pointer
                // leaves the strip (the m10-c gesture-driven cursor idiom).
                DragCursor.set(CursorAffordance.trackHeader.dragCursor)
                onReorderChanged(value.location.x)
            }
            .onEnded { value in
                DragCursor.clear()
                onReorderEnded(value.location.x)
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

    // MARK: Volume knob + pan

    /// The VOL | PAN knob row (m23-a). The round `VolumeKnob` is ADDITIVE — it
    /// sits beside the pan knob and drives the same `setTrackVolume` the fader
    /// below does, so a squeezed fader is never the only way to set a level.
    ///
    /// It renders in **BOTH densities** (a deliberate, reported decision): volume
    /// is the most beginner-primary control on a strip, and a Pro-only volume knob
    /// would be indefensible. The cost is honest — the row grows 38 → 52 pt, so a
    /// Simple strip's fader throw shortens by that much; at the measured window
    /// floor the reserved budget still fits with ~130 pt to spare
    /// (`MixerStripLayoutTests`).
    ///
    /// The VOL cell deliberately carries **no readout of its own**: the strip's dB
    /// number is the glowing `DbReadout` under the fader, and one value never gets
    /// two copies on one strip. PAN keeps its readout because it has no other — but
    /// it sits **on the label line**, not on a third line under the cap: a whole
    /// text line under the knobs cost 13 pt of every strip's vertical budget, which
    /// at the default window was the difference between a chain that fits and a
    /// chain that scrolls.
    private var knobSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                knobLabel("VOL")
                VolumeKnob(
                    gain: track.volume,
                    onChange: { store.setTrackVolume(id: track.id, volume: $0) }
                )
                .frame(width: 36, height: 36)
            }
            .explainable(.mixerVolumeKnob)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    knobLabel("PAN")
                    Text(MixerFormat.panString(track.pan))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .lineLimit(1)
                        // Pinned, never scaled (docs/DESIGN-LANGUAGE.md m22-g law).
                        // The widest string is 4 glyphs (`L100`) ≈ 24 pt; the row is
                        // 36 + 8 + (22 + 4 + 24) = 94 pt inside a 112 pt content box,
                        // so it can grow a glyph without touching the strip edge.
                        .fixedSize()
                }
                PanKnob(pan: track.pan, onChange: { store.setTrackPan(id: track.id, pan: $0) })
                    .frame(width: 36, height: 36)
            }
            .explainable(.mixerPan)
            Spacer(minLength: 0)
        }
        .frame(height: MixerStripLayout.knobRowHeight, alignment: .top)
    }

    /// A knob's micro-label — above the cap, the channel-strip convention.
    private func knobLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(DAWTheme.textDim)
            .lineLimit(1)
            .fixedSize()
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
        // The floor dropped 150 → `faderRegionFloor` in m23-a. 150 was a HARD
        // minimum that the strip exported to the whole console, so a tall chain
        // made the console demand more height than the window had — pushing the
        // app header and transport off-window and clipping this readout away. The
        // lower floor is the degradation valve: the fader compresses a little
        // before anything is ever lost, and the room maths above hands it every
        // point the signal-flow region doesn't take.
        .frame(minHeight: MixerStripLayout.faderRegionFloor)
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
/// `removeEffect`/`setEffectBypassed` for a track/bus, the master twins for
/// master, and built-in adds through the host's `onAddBuiltIn` funnel
/// (`AppModel.addBuiltInInsert` → the same `addEffect`/`addMasterEffect` the
/// `fx.add` wire verb calls, plus the editor auto-open) — exactly the methods
/// the `fx.*` wire verbs call (UI == wire). `addableEffectKinds` is already
/// the built-in set = exactly what the master chain accepts (built-ins only,
/// v1), so the menu needs no per-target filter; the master target opens no
/// plugin window — built-in inserts open the in-window EFFECT EDITOR card
/// instead (m17-a, `onOpenEditor`), on tracks, buses, AND the master chain.
struct MixerInsertsSection: View {
    var store: ProjectStore
    /// nil = the project master chain; non-nil = a track/bus by id.
    var trackID: UUID?
    var effects: [EffectDescriptor]
    /// Adds a built-in insert (m17-a): the host routes this through
    /// `AppModel.addBuiltInInsert`, which performs the store add AND auto-opens
    /// the new insert's effect editor card (the Logic add-then-open habit).
    /// The wire's `fx.add` never comes through here — agents must not pop UI.
    var onAddBuiltIn: (EffectDescriptor.Kind) -> Void
    /// Opens the AU-effect picker modal (m13-g, audit F6) — supplied by a track/bus
    /// host only, so the add-menu grows an "Audio Units…" item there. nil on the
    /// MASTER chain (built-ins only in v1, `masterChainBuiltInOnly`): hiding the
    /// item is the honest UI — no offer-then-error.
    var onAddAudioUnit: (() -> Void)?
    /// Opens an AU insert's plugin window (M3 vi-b) — supplied by a track/bus
    /// host only; nil on master (built-ins only).
    var onOpenWindow: ((UUID) -> Void)?
    /// Toggles the effect editor card on a BUILT-IN insert (m17-a) — routed to
    /// `AppModel.toggleEffectEditor` by every host (tracks, buses, master).
    var onOpenEditor: (UUID) -> Void
    /// The per-insert GR poll behind the dynamics chips' activity bar (m22-e)
    /// — routed to `AppModel.gainReductionDb` by every host (the grSeed-aware
    /// seam). This section hands it only to compressor/limiter/gate rows, so
    /// a reverb chip never even polls.
    var gainReductionFor: (UUID) -> Double?
    /// Whether the chain's ROWS are folded away (m23-a). A plain value input —
    /// the host owns the state (the console-wide `PanelLayoutStore` flag in the
    /// app, a `@State` in a preview) — so this component stays reusable.
    var isCollapsed: Bool = false
    /// Flips `isCollapsed`. nil = no disclosure at all (a host that never folds).
    var onToggleCollapsed: (() -> Void)?
    /// Fixed height for the ROWS area — the strip's insert reserve, which is what
    /// keeps the fader, the dB readout and Mute/Solo/Arm on one line however long a
    /// chain grows. Rows past the reserve scroll INSIDE it.
    ///
    /// Every strip class the app renders now passes one, and they DIFFER (m23-ax):
    /// a channel reserves 3 rows, a bus 5 (`insertsViewportHeight(room:isCollapsed:slots:)`,
    /// valve included), the master a flat 5 (`masterInsertsViewportHeight`, no valve —
    /// it rides its own scroller and so cannot clip).
    ///
    /// **nil = hug the rows, the pre-reserve behaviour.** ⚠️ This USED to be the
    /// master's mode, and the note here used to explain why the master kept hugging
    /// on purpose. m23-ax reversed that on the user's request — hugging is exactly
    /// what made every master insert push the fader and the LOUDNESS / STEREO IMAGE /
    /// REFERENCE blocks 28 pt further down. nil now means PREVIEWS and unit hosts
    /// only. A plain value input, like every other input here.
    var rowsViewportHeight: CGFloat?
    /// Reports what each row DREW (m23-s): its label, the pin flag, the
    /// intrinsic width, the name line's width, and every GR underline frame.
    /// A plain optional closure — nil in previews and unit hosts, so the section
    /// still stands alone; the app hands it `AppModel.insertLabels`.
    var onRowProbe: ((InsertRowProbe) -> Void)?

    /// Collapsed hides the ROWS, never the header: the section label, the count of
    /// what's hidden, and the "+" add menu stay reachable, so a folded chain can
    /// still be unfolded and added to.
    private var showsRows: Bool { !isCollapsed }

    var body: some View {
        // The spacing is `MixerStripLayout`'s, not a local 4: that constant is what
        // the measured reserve is COMPUTED from, so a view that spelled its own gap
        // could drift from the budget silently — the viewport would keep claiming to
        // seat three rows while seating two and a sliver.
        VStack(spacing: MixerStripLayout.insertRowSpacing) {
            HStack(spacing: 4) {
                if let onToggleCollapsed {
                    disclosure(onToggleCollapsed)
                }
                StripSectionLabel(text: "Inserts")
                // The chain LENGTH, always — not just while collapsed. The section
                // is bounded now (m23-a), so a long chain can be showing only its
                // first few rows; the count is what tells the truth about how many
                // there are, folded away or merely scrolled past.
                if !effects.isEmpty {
                    countBadge
                }
                addMenu
            }
            if !showsRows {
                EmptyView()
            } else if effects.isEmpty {
                emptyState
            } else if let rowsViewportHeight {
                // The reserve. A chain past 3 rows scrolls INSIDE this viewport, so
                // the section's height — and therefore every control below it on the
                // strip — never moves. Nested inside the region's own scroller, the
                // m23-m3c "inner per-section scrollers keep their own caps" idiom.
                ScrollView(.vertical) {
                    VStack(spacing: MixerStripLayout.insertRowSpacing) {
                        rows
                        remainderSlots
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: rowsViewportHeight)
            } else {
                rows
            }
        }
    }

    /// The chain's rows. One `InsertRow` per effect, in chain order.
    private var rows: some View {
        VStack(spacing: MixerStripLayout.insertRowSpacing) {
            ForEach(effects) { effect in
                InsertRow(
                    store: store,
                    trackID: trackID,
                    effect: effect,
                    onToggleBypass: { toggleBypass(effect) },
                    onRemove: { remove(effect) },
                    // AU inserts get one open-window button (M3 vi-b); built-in
                    // effects get the in-window effect editor card instead
                    // (m17-a, `onOpenEditor` below), and the master chain never
                    // hosts AUs so the window button stays nil there.
                    onOpenWindow: (trackID != nil && effect.kind == .audioUnit)
                        ? { onOpenWindow?(effect.id) }
                        : nil,
                    // Built-in kinds only: click the row (or its slider glyph)
                    // to toggle the generic param editor — AU rows keep their
                    // plugin-window affordance and never open the card (v1).
                    onOpenEditor: effect.kind != .audioUnit
                        ? { onOpenEditor(effect.id) }
                        : nil,
                    // Dynamics kinds only (m22-e): the chip's GR activity
                    // bar poll — every other kind stays bar-free (and
                    // never polls).
                    gainReduction: GainReductionMeterModel.isDynamicsKind(effect.kind)
                        ? { gainReductionFor(effect.id) }
                        : nil,
                    onProbe: onRowProbe
                )
            }
        }
    }

    /// The EMPTY slots that finish a partial chain, so the reserve reads as "three
    /// slots, one filled" rather than as a chip above an unexplained void — the state
    /// the user judged worse than the empty strip, because a chip over blank space
    /// reads as content that failed to load.
    ///
    /// Same chrome as the empty well (`InsertSlotWell` — one vocabulary, structurally,
    /// not two copies of the same modifiers). Nothing is drawn once the chain fills
    /// the reserve, so a 3-insert strip and a 4-insert strip look IDENTICAL at rest
    /// and only scrolling tells them apart: there is no 3→4 transition to smooth.
    ///
    /// The count comes from `MixerStripLayout`, which measures the chain by its rows'
    /// ACTUAL heights (a keyable compressor row is 42 pt, not 24) — so the remainder
    /// can never overflow the viewport and can never make it scroll when it wasn't.
    @ViewBuilder
    private var remainderSlots: some View {
        let count = MixerStripLayout.insertsRemainderSlots(
            viewport: rowsViewportHeight ?? 0,
            filledRowsHeight: filledRowsHeight)
        if count > 0 {
            ForEach(0..<count, id: \.self) { _ in
                // `Color.clear`, NOT `EmptyView()`: an EmptyView contributes no
                // layout node, so the well's frame/fill/stroke would hang off
                // nothing and the slot would silently not draw — measured, the
                // arithmetic tests stayed green while the rack showed no slots.
                InsertSlotWell(height: MixerStripLayout.insertRowHeight) { Color.clear }
            }
        }
    }

    /// What the chain occupies right now, row by row. NOT `effects.count × 24`: a
    /// keyable insert is taller, and scoring it short would draw one slot too many.
    private var filledRowsHeight: CGFloat {
        MixerStripLayout.insertsFilledRowsHeight(
            rowHeights: effects.map {
                InsertRow.isKeyable(effect: $0, trackID: trackID)
                    ? MixerStripLayout.keyableInsertRowHeight
                    : MixerStripLayout.insertRowHeight
            })
    }

    /// The empty chain, in its two presentations.
    ///
    /// **Reserved** (a channel/bus strip): the space is held open whether or not the
    /// track has effects, so the empty state has to read as **deliberate space**, not
    /// as a panel that failed to draw. It fills the whole reserve with a dashed
    /// hairline outline — the house's "prospective content" chrome, the same one the
    /// ghost note lane and the automation lane hint wear — around centred, dim copy:
    /// the existing "No inserts" label (one vocabulary) over a fainter line pointing
    /// at the affordance that fills it. No glow (Rule 3 — nothing static glows), no
    /// accent (an empty chain is not an earned state), and no claim about how many
    /// slots there are, so the copy stays true if the reserve ever degrades.
    ///
    /// **Unreserved** (previews and unit hosts — no longer the master, m23-ax):
    /// byte-identical to the pre-reserve line. The well exists because there is space
    /// to hold open; where nothing is held open, an outlined box around one word would
    /// be decoration.
    @ViewBuilder
    private var emptyState: some View {
        if let rowsViewportHeight {
            // ONE well with the copy in it — deliberately NOT three empty outlines.
            // A whole empty chain has something to say ("No inserts / Add with +"),
            // and three boxes around one label is the grid-of-empty-boxes the design
            // rules warn against. The partial chain draws per-slot wells instead
            // (`remainderSlots`) because there the slots are what needs saying. Same
            // chrome either way — `InsertSlotWell` is the single definition.
            InsertSlotWell(height: rowsViewportHeight) {
                VStack(spacing: 2) {
                    Text("No inserts")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textSecondary)
                    Text("Add with +")
                        .font(.system(size: 8))
                        .foregroundStyle(DAWTheme.textFaint)
                }
                .lineLimit(1)
            }
            .help("No effects on this track yet. The strip keeps this space open either way, so the fader never moves when you add one.")
        } else {
            Text("No inserts")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    /// The fold/unfold chevron (m23-a). NEUTRAL chrome per Rule 3 — a disclosure
    /// is not an earned active state, so no accent and no glow at rest, only the
    /// standard hover brighten (the `PluginWindowButton` idiom).
    private func disclosure(_ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed
              ? "Show this track's effects again"
              : "Fold the effects away to give the volume fader more room")
    }

    /// How many effects the chain holds — so a folded (or merely scrolled) chain
    /// never reads as a shorter one. SF Mono (it is a number) on quiet chrome;
    /// neutral, because a count is information, not an earned active state.
    private var countBadge: some View {
        Text("\(effects.count)")
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(DAWTheme.panelRaised)
            .clipShape(Capsule())
            // Pinned, never scaled (the m22-g law) — at most 2 glyphs.
            .fixedSize()
            .help(isCollapsed
                  ? "\(effects.count) effect\(effects.count == 1 ? "" : "s") folded away"
                  : "\(effects.count) effect\(effects.count == 1 ? "" : "s") in this chain")
    }

    private var addMenu: some View {
        Menu {
            ForEach(addableEffectKinds, id: \.self) { kind in
                Button(MixerFormat.effectDisplayName(EffectDescriptor(kind: kind))) {
                    // m17-a: the host's add funnel — store add + editor auto-open.
                    onAddBuiltIn(kind)
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

/// The house's "prospective content" chrome — a dashed hairline outline over a
/// barely-raised fill, the same vocabulary the ghost note lane and the automation
/// lane hint wear. It says "something belongs here", never "something is missing".
///
/// **ONE definition for BOTH places the inserts reserve shows held-open space**: the
/// labelled empty well (a whole empty chain) and the empty slots that finish a
/// partial chain. Two copies of these modifiers would drift and the two states would
/// stop reading as the same idea — the `ArrangeDropSnap` "make divergence
/// unrepresentable" idiom, applied at view scale.
///
/// Deliberately quiet, and it has to stay that way: most strips run one or two
/// inserts, so these outlines are visible across the whole rack. No glow and no
/// accent (Rule 3 — an unused slot is not an earned state), a hairline stroke rather
/// than a border, and a fill barely above the panel. Against a filled chip's solid
/// ground and lit bypass dot it recedes, which is what keeps the rack reading as
/// recessed structure instead of a grid of empty boxes competing with the chips.
private struct InsertSlotWell<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(DAWTheme.panelRaised.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(DAWTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .frame(height: height)
    }
}

/// The master strip: accent-bordered and wider, pinned at the right of the
/// console. Volume fader + stereo output meter + digital dB readout, and — in
/// Pro (m13-d) — the master INSERT chain: effects on the whole mix, post-fader
/// (the last stop before the speakers), built-ins only in v1. Simple hides the
/// section (the density-honesty rule), leaving the fader a longer throw.
struct MixerMasterStrip: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    /// The mixer console's shared density store (`MixerView.panelID`) — read so
    /// the master strip reveals its inserts only in Pro, exactly like the
    /// channel strips.
    var densityStore: PanelDensityStore
    /// The console's shared layout store (m23-a) — the INSERTS disclosure flag,
    /// shared with every channel strip (the console is ONE panel).
    var layoutStore: PanelLayoutStore

    /// Pro density reveals the master insert chain (Simple: fader + meters only).
    private var isPro: Bool { densityStore.density(forPanel: MixerView.panelID) == .pro }

    var body: some View {
        // ONE internal vertical scroller (m23-a) — the m17-f F4 compression law
        // for a fixed-width panel, applied to the master strip.
        //
        // **Why the master needs a different answer than a channel strip.** A
        // channel strip can reserve its fader cluster and yield the chain, because
        // its content fits. The master's cannot: since m22-c/d/g it carries the
        // chain, the automation lane, the fader, LOUDNESS, STEREO IMAGE and the
        // REFERENCE row — ~690 pt together, more than the ~430 pt a strip gets at
        // the measured window floor. Before m23-a that intrinsic minimum was
        // exported to the console, which has no vertical scroll, so it shoved the
        // app header row and the transport bar clean off the window and then let
        // the strip's own `clipShape` cut whatever still didn't fit — unreachable.
        // Now it scrolls: nothing is lost, everything is reachable.
        //
        // **`minHeight: viewport` on the content** is the arrange shared-scroll
        // idiom: when the content is SHORTER than the viewport it stretches to fill
        // (the greedy fader absorbs the slack and keeps its long throw), and only
        // when it is taller does the scroller actually scroll. At the app's default
        // 1440×900 that means the strip renders exactly as it did before m23-a.
        //
        // **The identity block scrolls with everything else** — a deliberate
        // deviation from F4's "pinned header". Pinning it would cost 52 pt of
        // viewport, which is enough to turn a strip that fits at the DEFAULT window
        // into one that scrolls; and unlike the Sketchpad/ClipFix panels F4 was
        // written for, this header holds no controls (no close, no toggle) and the
        // strip is unmistakable anyway by its cyan accent border and glow.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                masterBody
                    .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.visible)
        }
        .padding(MixerStripLayout.masterStripHorizontalPadding)
        .frame(width: MixerStripLayout.masterStripWidth)
        .frame(maxHeight: .infinity)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.playback.opacity(0.4), lineWidth: 1.5)
        )
        .glow(DAWTheme.playback, radius: 8, intensity: 0.12)
    }

    /// The whole strip's anatomy — the scroller's content.
    private var masterBody: some View {
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
                    onAddBuiltIn: { kind in
                        // m17-a: master adds auto-open the editor too — the card is
                        // the master chain's ONLY in-app param surface (built-ins
                        // only, no plugin windows).
                        model.addBuiltInInsert(trackID: nil, kind: kind)
                    },
                    onOpenWindow: nil,
                    onOpenEditor: { effectID in
                        model.toggleEffectEditor(trackID: nil, effectID: effectID)
                    },
                    gainReductionFor: { effectID in
                        model.gainReductionDb(trackID: nil, effectID: effectID)
                    },
                    isCollapsed: layoutStore.mixerInsertsCollapsed,
                    onToggleCollapsed: {
                        layoutStore.setMixerInsertsCollapsed(!layoutStore.mixerInsertsCollapsed)
                    },
                    // m23-ax — the master's reserve. Until now this was nil: the
                    // master HUGGED its chain, so every insert pushed the fader, the
                    // dB readout, LOUDNESS, STEREO IMAGE and the REFERENCE row 28 pt
                    // further down (205 pt across an 8-insert chain, measured), and a
                    // long chain had nowhere to scroll except by scrolling the whole
                    // strip past everything else.
                    //
                    // **No `room` argument, deliberately** — see
                    // `masterInsertsViewportHeight`. The valve a channel needs exists
                    // to stop an over-tall reserve clipping the fader inside a region
                    // that cannot scroll; the master's whole anatomy already rides the
                    // scroller above, so the reserve can be flat.
                    rowsViewportHeight: MixerStripLayout.masterInsertsViewportHeight(
                        isCollapsed: layoutStore.mixerInsertsCollapsed),
                    onRowProbe: { model.insertLabels.record($0) }
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
            .frame(minHeight: MixerStripLayout.masterFaderRegionFloor)
            .explainable(.mixerMaster)
            DbReadout(gain: store.masterVolume)
            Divider().overlay(DAWTheme.playback.opacity(0.25))
            MasterLoudnessReadout()
            Divider().overlay(DAWTheme.playback.opacity(0.25))
            // Stereo image / mono safety (m22-d): the goniometer well is Pro
            // (the Lissajous cloud is a pro instrument; Simple keeps the
            // fader's long throw), but the plain-language phase verdict + bar
            // read in BOTH densities — "will it survive a phone speaker?" is
            // beginner-relevant, the LOUDNESS block's sibling. The closures
            // prefer the `debug.scopeSeed` override (deterministic captures)
            // over the live engine polls — the `vibeSeed` idiom.
            MasterStereoImageBlock(
                showsScope: isPro,
                scopeFrame: { model.scopeSeed?.frame ?? store.masterScopeFrame() },
                analysis: {
                    if let seed = model.scopeSeed {
                        var seeded = MasterAnalysisSnapshot.floor
                        seeded.correlation = seed.correlation
                        seeded.width = seed.width
                        seeded.balance = seed.balance
                        return seeded
                    }
                    return store.masterAnalysis()
                },
                // The m23-r3b tick witness. TWO reporters, because the trail and
                // the readouts tick in SEPARATE TimelineViews at different rates
                // and either can freeze alone — one shared reporter could not
                // tell which site stopped.
                onTrailFrame: { points, calm, zone in
                    model.liveLayers.recordTrailFrame(points: points, calm: calm, zone: zone)
                },
                onReadoutFrame: { snapshot, zone in
                    model.liveLayers.recordReadoutFrame(snapshot, zone: zone)
                }
            )
            // Reference track (m22-g): rendered ONLY when the project carries a
            // reference slot, so every project without one pays exactly zero —
            // no row, no poll, no divider. Both densities: an A/B listening
            // check is beginner-relevant (the stereo block's "phone speaker"
            // argument). The seed override comes first, the `scopeSeed` idiom.
            if model.referenceRowSlot != nil {
                Divider().overlay(DAWTheme.playback.opacity(0.25))
                MasterReferenceRow(model: model.referencePanel,
                                   onOpen: { model.openReferencePanel() })
            }
        }
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
                },
                // m23-ai: DELIBERATELY nil. This master lane lives in the MIX
                // workspace, and `ContentView`'s root is a `switch
                // model.workspaceMode` with `.arrange` and `.mix` as mutually
                // exclusive ViewBuilder branches — so this editor is never a
                // descendant of `ArrangeDeleteKey`, the one place in the app
                // that consumes ← / →, and can never receive the key this guard
                // is about. Reporting from here would claim the arrange's arrow
                // keys on behalf of a lane the arrange cannot even see; the
                // workspace switch is a real teardown, so `.onDisappear` would
                // usually clear it, but "usually" is exactly the latch hazard
                // the bridge's doc comment warns about. Nothing to guard, so
                // nothing is reported.
                pointSelection: nil
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

/// The master strip's compact **REFERENCE row** (m22-g P3, design §7.1) —
/// rendered only when the project carries a reference slot (the caller gates
/// it), in BOTH densities.
///
/// Anatomy: a `REF` micro-label with the reference's tail-truncating name over
/// the shared MIX|REF chip pair and the SF Mono match-gain readout. Clicking
/// the name row opens the REFERENCE panel; the whole block carries
/// `.explainable(.referenceRow)` and the chip carries the SHARED
/// `.referenceABToggle` id it also carries in the panel.
///
/// **Two lines, ≈32 pt — an argued deviation from §7.1's "one compact 25 pt
/// row"**: the master strip is 156 pt wide with 12 pt padding, leaving 132 pt
/// of content width, and the chip + readout pair below already claims 114 of
/// it. One line would need label + name + chip + readout in 132 pt — 18 pt
/// left over, which cannot even hold the `REF` label (≈20 pt), let alone a
/// name. It would either truncate the name to nothing or fork the chip into a
/// narrower second copy — and a second copy is exactly what the "ONE shared
/// control" rule forbids. Stacking costs ≈7 pt over the design's budget and
/// keeps both the name and the chip's pixel identity.
///
/// **Line 2's width budget (re-measured 2026-08-05, m23-dt):** chip 69 pt + 6 pt
/// spacing + the widest possible readout 43 pt (`-24.0 dB`, 8 glyphs — the
/// match gain is bounded by `ReferenceSlot.trimRangeDb` = ±24) = 118 pt inside
/// 132, so `Spacer(minLength: 0)` absorbs ≈14 pt. Both the chip and the readout
/// therefore PIN their widths (`fixedSize`) instead of competing: HStack's
/// proposal split, not a real overflow, WAS collapsing the chip to `M… | R…`
/// whenever the readout grew a glyph. Line 1's tail-truncating NAME stays the
/// row's one honest place to lose characters.
///
/// ⚠️ **The chip figure was 65 pt here until m23-dt measured it at 69** — off
/// `debug.explainFrames` (`referenceABToggle` = 69×18 pt at x 1230, row 132×32
/// at y 826), which is 4 pt of budget this paragraph had been quietly spending
/// twice. Re-derive from the seam, never from this prose.
///
/// ⚠️ **BOTH PINS ARE PRECAUTIONARY AND UNEXERCISED AT THESE WIDTHS** (m23-dt).
/// With ≈14 pt of slack the `Spacer` absorbs the residual, so removing EITHER
/// `.fixedSize` alone moves ZERO pixels — the squeeze described above is HISTORY
/// (the m22-g P3 regression), not a constraint currently biting. They are kept
/// deliberately: a `minimumScaleFactor` would hide a real future overflow, and
/// the pins keep one VISIBLE. The pin that becomes load-bearing first is the
/// chip's own, in `ReferenceABToggle` — measured at m23-be by widening the `dB`
/// unit past the slack, at which point dropping it fans the chip out to one
/// width per glyph. `m22g-reference-panel.mjs` leg **E2c** is what notices if a
/// future edit grows the readout past the row's slack; it is green today
/// (50 PASS / 0 FAIL, chip byte-identical `455e08d59005` at all five gains).
///
/// Poll cadence: 5 Hz UNPAUSED `.periodic` (the `MasterLoudnessReadout`
/// pattern) — the monitor state and match gain both move from the wire, so the
/// row must keep reading them while the app is not frontmost (the m22-e law).
struct MasterReferenceRow: View {
    var model: ReferencePanelModel
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Text("REF")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(DAWTheme.textSecondary)
                    Text(model.slot?.name ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the reference panel — compare your mix to \(model.slot?.name ?? "the reference").")
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let status = model.status
                HStack(spacing: 6) {
                    ReferenceABToggle(isMonitoring: status.monitoring) {
                        model.setMonitor($0)
                    }
                    .explainable(.referenceABToggle)
                    Spacer(minLength: 0)
                    matchGain(status)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .explainable(.referenceRow)
    }

    /// Cyan while monitoring (dB readouts are cyan), AMBER when the ceiling
    /// clamp reduced the gain — the same honesty the panel shows, one surface
    /// over. A faint dash when there is nothing to match yet.
    private func matchGain(_ status: ReferenceStatus) -> some View {
        let db = ReferencePanelModel.displayedMatchGainDb(status)
        let clamped = status.ceilingLimited == true
        let tint: Color = db == nil ? DAWTheme.textFaint
            : (clamped ? DAWTheme.record : DAWTheme.playback)
        return HStack(spacing: 2) {
            Text(ReferencePanelModel.matchGainText(db))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .glow(tint, radius: 3, intensity: (db == nil || !status.monitoring) ? 0 : 0.35)
            if db != nil {
                Text("dB")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
            }
        }
        .lineLimit(1)
        // Pinned, NOT scaled. `ReferenceSlot.trimRangeDb` bounds the match gain
        // at ±24 dB, so the widest string this can ever render is 8 glyphs
        // (`-24.0 dB`) ≈ 43 pt — which fits beside the 69 pt chip inside the
        // strip's 132 pt of content width with ~14 pt to spare. A
        // `minimumScaleFactor` here would turn any future squeeze into a
        // silently-shrunken primary number that no pixel gate would flag;
        // pinning keeps a genuine overflow VISIBLE.
        //
        // ⚠️ PRECAUTIONARY, AND CURRENTLY INERT (m23-dt, measured at m23-be with
        // the row proven rasterized): at these widths the `Spacer(minLength: 0)`
        // absorbs the residual, so removing this pin alone changes NOTHING on
        // screen. That is not a reason to delete it — it is the guard that keeps
        // a future overflow visible instead of silently scaled. A pin is inert
        // or load-bearing AT A WIDTH, and this one is inert at today's.
        .fixedSize(horizontal: true, vertical: false)
        .help(clamped
              ? "The reference is turned down further than a level match asks for, so it cannot clip."
              : "How much the reference is turned up or down to sit at your mix's loudness.")
    }
}

/// Live loudness readout on the master strip (m22-c): momentary /
/// short-term / running-integrated LUFS, loudness range (LU), and true
/// peak (dBTP) — the SAME snapshot `mixer.liveLoudness` serves (UI == wire
/// by construction; the DSP is DAWCore's shared BS.1770/EBU 3341+3342
/// stream on the master tap). TimelineView-polled like the vibe meter, but
/// at 5 Hz — these are numbers, not motion, and momentary itself only
/// refreshes every 100 ms hop. While the analyzer warms up (nil = no
/// evidence, never 0) values read as a faint "–" placeholder and the block
/// dims — per DESIGN-LANGUAGE, SF Mono digital readouts, semantic cyan
/// only, no new colors.
struct MasterLoudnessReadout: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let snapshot = (try? store.liveLoudness()) ?? .empty
            let warming = snapshot.momentaryLufs == nil
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("LOUDNESS")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(DAWTheme.textDim)
                    Spacer(minLength: 0)
                    Text("LUFS")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(DAWTheme.textFaint)
                }
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                    GridRow {
                        label("M"); value(snapshot.momentaryLufs, warming: warming)
                        label("S"); value(snapshot.shortTermLufs, warming: warming)
                    }
                    GridRow {
                        label("I"); value(snapshot.integratedLufs, warming: warming)
                        label("LRA"); value(snapshot.loudnessRangeLu, warming: warming)
                    }
                    GridRow {
                        label("TP"); value(snapshot.truePeakDbtp, warming: warming)
                        label(""); unit("dBTP")
                    }
                }
            }
            .opacity(warming ? 0.75 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live loudness")
            .accessibilityValue(accessibilityValue(snapshot))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(DAWTheme.textDim)
            .frame(minWidth: 14, alignment: .leading)
    }

    private func unit(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(DAWTheme.textFaint)
    }

    /// One SF Mono value; nil (not enough audio yet) reads as a faint dash
    /// — absence is the honest display, never a fabricated 0/floor.
    private func value(_ number: Double?, warming: Bool) -> some View {
        Text(number.map { String(format: "%.1f", $0) } ?? "–")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(number == nil ? DAWTheme.textFaint : DAWTheme.playback)
            .glow(DAWTheme.playback, radius: 3, intensity: number == nil ? 0 : 0.35)
            .lineLimit(1)
    }

    private func accessibilityValue(_ snapshot: LiveLoudnessSnapshot) -> String {
        guard let momentary = snapshot.momentaryLufs else { return "warming up" }
        var parts = [String(format: "momentary %.1f LUFS", momentary)]
        if let integrated = snapshot.integratedLufs {
            parts.append(String(format: "integrated %.1f LUFS", integrated))
        }
        if let range = snapshot.loudnessRangeLu {
            parts.append(String(format: "range %.1f LU", range))
        }
        if let truePeak = snapshot.truePeakDbtp {
            parts.append(String(format: "true peak %.1f dBTP", truePeak))
        }
        return parts.joined(separator: ", ")
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
