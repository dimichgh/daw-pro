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

    /// LIVE LOOPING (m34-h-2) — the loop length the LOOPER chip will open with.
    ///
    /// ⚠️⚠️ **THE INITIAL VALUE IS THE PRODUCT DEFAULT, NOT THE API DEFAULT.**
    /// `ProjectStore.beginLoopDeck(bars:)` defaults to `nil`, which means
    /// PRESS-TO-END; the product default is FIXED BARS, 4. Held here rather than
    /// inside `LoopDeckControls` so a Pro user's bar count survives the view
    /// swapping between its door and its session form.
    @State private var deckLength: LoopDeckControlModel.LengthChoice =
        LoopDeckControlModel.defaultLength

    /// TB-F1 — the two measurements the fit rule needs, taken from the bar's own
    /// layout (`onGeometryChange` in `body`). ⚠️ **NEITHER DEPENDS ON THE PLAN, AND
    /// THAT IS THE POINT:** the bar's width is its proposal (the outer frame is
    /// `minWidth: 0, maxWidth: .infinity`), and the leading cluster is fixed-size
    /// content. A probe on the RIGHT region itself would report its OVERFLOWING
    /// width once it no longer fits — and a rule fed that number would conclude
    /// there was room and never compact anything. Zero until the first layout,
    /// which the rule reads as "no room": the first frame is the tightest plan,
    /// never an overflowing one.
    @State private var barWidth: CGFloat = 0
    @State private var leadingClusterWidth: CGFloat = 0

    /// TB-F1 — which of the right region's controls take their compact form
    /// (`TransportBarFit`, pure and pinned by `TransportBarFitTests`). TB's
    /// word-drops (KEYS, EXPORT, the door) stay `ViewThatFits`; this decides only
    /// the gives TB could not make — the test tone, the notices count, and the
    /// looper's compact forms — and only when they are unavoidable.
    private var fitPlan: TransportBarFit.Plan {
        TransportBarFit.plan(
            regionWidth: TransportBarFit.regionWidth(barWidth: barWidth,
                                                     leadingClusterWidth: leadingClusterWidth),
            state: TransportBarFit.State(
                isPro: isPro,
                looper: store.loopDeckStatus.map { TransportBarFit.Looper.open(lamps: $0.lamps.count) }
                    ?? .closed,
                noticeCount: store.engineNotices.count))
    }

    /// Which loop-deck controls are live right now, and the sentence each shows
    /// when it is not. ⚠️ The bar's house idiom is `try? store.verb()`, which
    /// swallows the store's teaching refusals whole — this resolver is what lets
    /// the controls disable and EXPLAIN instead of accept and discard. The store
    /// stays authoritative; `LoopDeckControlModelTests` pins the two in
    /// agreement against a real store.
    private var loopDeckControlModel: LoopDeckControlModel {
        let status = store.loopDeckStatus
        return LoopDeckControlModel.resolve(
            hasSession: status != nil,
            isPlaying: store.transport.isPlaying,
            isRecording: store.transport.isRecording,
            isTransportLoopEnabled: store.transport.isLoopEnabled,
            pendingPhase: status?.pendingPhase,
            canPeel: status?.canPeel ?? false,
            instrumentTracks: store.tracks
                .filter { $0.kind == .instrument }
                .map { LoopDeckControlModel.TrackChoice(id: $0.id, name: $0.name) },
            activeTrackID: appModel.activeTrackID)
    }

    /// The leading cluster's fixed width — the Position/Time anchor.
    static let leadingAnchorWidth: CGFloat = 340

    var body: some View {
        HStack(spacing: TransportBarFit.clusterSpacing) {
            // The LEADING CLUSTER, one fixed-size group so the fit rule can
            // measure it (TB-F1). Same items, same 20 pt spacing, same place.
            HStack(spacing: TransportBarFit.clusterSpacing) {
                // Fixed leading width so PUNCH hiding closes the chip row up (LOOP +
                // CLICK go adjacent) WITHOUT moving the Position/Time readouts — the
                // bar's visual anchor. The freed room reads as breathing room before
                // the section Divider, never a PUNCH-shaped hole in the row.
                //
                // ⚠️ PINNED, then framed (TB): the cluster is laid out at its OWN
                // width and never squeezed to fit the anchor. Before TB it was
                // squeezed in Pro at EVERY window width — see `transportButtons`.
                transportButtons
                    .fixedSize()
                    .frame(width: Self.leadingAnchorWidth, alignment: .leading)

                Divider().frame(height: 36).overlay(DAWTheme.hairline)

                // ⭐ A NUMBER NEVER SHRINKS (TB, the m22-g law). Every readout is
                // PINNED — `.fixedSize()` AFTER its `minWidth` frame, so the pin is
                // `max(minWidth, ideal)` and a long value (`1000.1`) grows the cell
                // instead of drawing past it. Before TB the three were compressible,
                // and at the 1208 pt window floor the tempo read `12…`. The room a
                // narrow window lacks is found on the RIGHT (the collapsing chips).
                DigitalReadout(
                    label: "Position",
                    value: store.transport.barsBeatsDisplay,
                    color: DAWTheme.playback,
                    valueSize: 24
                )
                .frame(minWidth: 76, alignment: .leading)
                .fixedSize()
                .explainable(.transportPosition)

                DigitalReadout(
                    label: "Time",
                    value: store.transport.clockDisplay,
                    color: DAWTheme.playback
                )
                .frame(minWidth: 104, alignment: .leading)
                .fixedSize()
                .explainable(.transportTime)

                tempoCluster
                    .fixedSize()
                    .explainable(.transportTempo)
            }
            // TB-F1 probe ②: content-sized, so it grows with a 4-digit bar or a
            // 10-minute clock and the rule takes that room from the right region.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                leadingClusterWidth = $0
            }

            rightRegion
        }
        .padding(.horizontal, TransportBarFit.barHorizontalPadding)
        .padding(.vertical, 10)
        // ⭐ IF THE BAR STILL CANNOT FIT, IT OVERFLOWS TO THE RIGHT (TB). The
        // default was to CENTRE an over-wide row, which cut the return-to-zero
        // button off the LEFT edge and moved Position/Time with it (measured,
        // Pro at the 1208 pt floor). Leading-anchored, the glass panel's clip
        // cuts the far-right mode chip instead, and the transport controls
        // never leave the window. A no-op whenever the bar fits.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        // TB-F1 probe ①: this frame takes exactly its proposal (min 0, max ∞), so
        // its width is the bar's, whatever the content does — never the plan's.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            barWidth = $0
        }
        .glassPanel()
    }

    /// The right region's give-way ORDER (TB) — the LOWEST priority gives
    /// first. `layoutPriority` is what makes it an order: the stack offers the
    /// higher-priority chips the room first, so a chip keeps its wider form for
    /// as long as the gaps and every lower-priority chip can pay for it.
    ///
    /// ⭐ **A GIVE THAT LOSES NO WORD GOES BEFORE ONE THAT DOES.** In Pro the
    /// loop deck's first give only re-stacks it (the length choice rides under
    /// the door, every word still on screen), so it goes first. Then the chips
    /// drop their words in order of how well the glyph reads ALONE: EXPORT (the
    /// share arrow), then KEYS (a piano), and — in Simple, where the deck's only
    /// give IS its word — the LOOPER door last, because a stack of squares says
    /// nothing on its own. MEASURED, Pro: every word shows down to ~1300 pt,
    /// and the window floor still fits with all three gives taken.
    private var collapsePriority: (keys: Double, deck: Double, export: Double) {
        isPro ? (keys: 3, deck: 1, export: 2) : (keys: 2, deck: 3, export: 1)
    }

    /// Everything right of the tempo readout, right-packed.
    ///
    /// ⭐⭐ **THE NARROW-WINDOW RULE (TB, 2026-09-25): NO LABEL BREAKS INSIDE A
    /// WORD, AND THE ROOM IS MADE HERE, IN THIS ORDER.** At the 1208 pt window
    /// floor this region used to be handed less than its width and SwiftUI
    /// squeezed whatever would squeeze: `KEY`/`S`, `LOO`/`PER`, `EXP`/`ORT`, the
    /// mode chip as `S…`/`P…` (and in Pro the whole bar overflowed the
    /// window). Now every label and readout is pinned, and the region gives
    /// way in a fixed order as the window narrows — first the gaps between its
    /// controls close from 20 pt to 8 (`TransportGap`), then the chips give in
    /// `collapsePriority` order. Each give is a `ViewThatFits` of a wider and a
    /// narrower form; a chip's glyph-only form is `TransportChipFace`, and its
    /// word stays in the tooltip and the accessibility label.
    ///
    /// MEASURED at 1208 × 672 (explain frames): the left cluster is 741 pt of
    /// the 1184 the window gives the bar, leaving this region 443. Simple's
    /// full region is 513.5 at 20 pt gaps; Pro's is 694.
    ///
    /// ⭐⭐ **AND WHAT TB'S GIVES COULD NOT PAY FOR, `fitPlan` DOES (TB-F1,
    /// 2026-09-27).** With every TB give taken, three states still overflowed the
    /// floor and the glass clip cut the master meter and the mode toggle: a
    /// looper session (Simple +66.5 pt, Pro +112.5) and Pro's notices chip
    /// (+38.5). Those surfaces are stateful, so no `ViewThatFits` may choose them;
    /// the pure rule does, from the MEASURED width this region is offered, taking
    /// the cheapest set of gives that fits: the test tone shrinks (no word lost),
    /// then the notices chip drops its count, then the looper compacts. Whatever
    /// room is left, TB's `ViewThatFits` chips take back as words.
    private var rightRegion: some View {
        let plan = fitPlan
        return HStack(spacing: 0) {
            // `minLength: 0` — the outer stack's 20 pt already separates this
            // region from the tempo readout.
            Spacer(minLength: 0)

            // ⭐ MUSICAL TYPING (m23-ct) — THE ONLY REAL-TIME NOTE INPUT THIS USER
            // CAN HAVE (they own no hardware controller). Shows in BOTH densities,
            // NOT gated on `isPro`: by Rule 6 a beginner needs a way to play a note
            // more than a pro does, and hiding the only performance surface behind
            // a mode chip would be the same "a fully-built subsystem with no door"
            // the item was filed about.
            //
            // Right-region, past the Spacer, so it never touches the 340 pt readout
            // anchor — Position/Time stay put (the export button's rule).
            musicalTypingToggle
                .explainable(.musicalTyping)
                .layoutPriority(collapsePriority.keys)

            TransportGap()

            // ⭐ LIVE LOOPING (m34-h-1 strip, m34-h-2 controls) — the loop
            // deck's surface: the LOOPER chip that OPENS a session, and, once
            // one is open, the lamp strip plus arm/finish/peel/end.
            //
            // ⚠️⚠️ **THIS USED TO BE `if let deck = store.loopDeckStatus`, AND
            // THAT GATE WAS THE WHOLE DEFECT m34-h-2 EXISTS TO FIX.** The strip
            // appeared only once a session existed, and nothing anywhere in the
            // app could create one — the only door to a fully-built, fully-
            // tested looper was an AI agent over MCP. The presence rule is now
            // INVERTED at the top level: the door is always here, and the strip
            // still appears only with a session (the "no clutter when there is
            // nothing to say" rule the engine-notices chip follows).
            //
            // Shows in BOTH densities, NOT gated on `isPro`, for the musical
            // typing strip's reason (Rule 6): this is the ONLY surface that
            // tells a performer which layer is armed and which is recording,
            // and hiding a live performance indicator — or its only entry
            // point — behind a mode chip would be exactly the "fully-built
            // subsystem with no door" problem. **Pro reveals only the LENGTH
            // CHOICE** (bar stepper + FREE); see `LoopDeckControls`.
            //
            // Right-region, past the Spacer, so it never touches the 340 pt
            // readout anchor — Position/Time do not move when a session opens
            // or closes. ⚠️ The door is ALWAYS present, so unlike the strip it
            // costs right-region width permanently; it is deliberately the
            // narrowest chip in that region at rest (one glyph + "LOOPER").
            LoopDeckControls(
                status: store.loopDeckStatus,
                playheadBeat: store.transport.positionBeats,
                model: loopDeckControlModel,
                isPro: isPro,
                // TB-F1: the rule's choice — never a `ViewThatFits`, because the
                // open deck is stateful and animated.
                form: plan.looper,
                lampBoxWidth: plan.lampBoxWidth,
                length: $deckLength,
                // ⚠️ `_ = try?`, NOT a bare `try?`: `@discardableResult` does NOT
                // survive the `try?` wrapper (the OPTIONAL it produces is a new,
                // non-discardable value), and this tree builds at zero warnings.
                //
                // ⚠️⚠️ AND THE DISCARD IS SAFE ONLY BECAUSE `loopDeckControlModel`
                // ALREADY PREDICTED THE REFUSAL — every one of these controls is
                // `.disabled` with the store's own reason on its tooltip when the
                // store would throw. A bare `try?` here WITHOUT that resolver is
                // precisely the dead press m34-h-2 exists to remove.
                onStart: { choice in _ = try? store.beginLoopDeck(bars: choice.barsParameter) },
                onArm: { trackID in _ = try? store.armLoopLayer(trackID: trackID) },
                onFinish: { _ = try? store.finishLoopLayer() },
                onPeel: { _ = try? store.peelLoopLayer() },
                onEnd: { _ = try? store.endLoopDeck() },
                onToggleMute: { layerID, muted in
                    _ = try? store.setLoopLayerMuted(layerID: layerID, muted: muted)
                }
            )
            .explainable(.loopDeck)
            .layoutPriority(collapsePriority.deck)

            TransportGap()

            // EXPORT: bounce the whole mix to a file. A core beginner action, so it
            // shows in BOTH densities. Right-region, past the Spacer — it never
            // touches the 340 pt readout anchor on the left (Position/Time stay put).
            exportButton
                .explainable(.transportExport)
                .layoutPriority(collapsePriority.export)

            // Pro-only diagnostic. Right-packed, so hiding it only grows the
            // Spacer — the master cluster and the mode chip stay put. Its narrow
            // form (TB-F1) is the rule's first give: smaller, not wordless — it
            // never had a word.
            if isPro {
                TransportGap()
                testToneButton(compact: plan.testTone == .compact)
                    .explainable(.transportTestTone)
            }

            // Engine-notices chip (m15-e, audit F6): appears ONLY when the store's
            // coalesced notices ring is non-empty (a healthy session shows nothing —
            // no clutter). Semantic AMBER warning (`DAWTheme.record`, the accent
            // system's warning/clipping-adjacent hue). DENSITY DECISION (documented):
            // it shows in BOTH Simple and Pro — NOT gated on `isPro`. Two reasons:
            // (1) it is read-only diagnostic STATUS chrome, not an edit affordance, so
            // the vibe-meter doctrine applies (status readouts show in both densities);
            // (2) Rule 6 — a beginner whose fades silently vanished needs to know MORE
            // than a pro, not less, so hiding a "something sounded off" indicator from
            // Simple would be user-hostile. Click toggles the popover list.
            if !store.engineNotices.isEmpty {
                TransportGap()
                noticesChip(compact: plan.notices == .compact)
                    .explainable(.transportEngineNotices)
            }

            // The session vibe meter — the signature glowing instrument (vm-b). It's
            // read-only STATUS chrome, so it shows in BOTH Simple and Pro, sitting just
            // left of the master cluster. Reads the seed override, else the live poll.
            TransportGap()
            VibeMeterView(snapshot: { appModel.vibeSeed ?? store.masterAnalysis() },
                          onFrame: { appModel.liveLayers.recordVibeFrame($0) })
                .frame(width: TransportBarFit.vibeMeterWidth, height: 44)
                .explainable(.vibeMeter)

            TransportGap()
            masterCluster
                .explainable(.transportMasterFader)

            TransportGap()

            // The bar's mode chip, pinned far-right (past the master cluster) so
            // it never reads as part of the record cluster and its presence never
            // reflows Position/Time.
            SimpleProToggle(
                store: densityStore,
                panelID: Self.panelID,
                help: "Simple: play, loop, click, tempo. Pro: punch recording, test tone."
            )
            // Pinned at the call site (TB): the shared chip does not pin its own
            // width, and at the floor it was squeezed to `S…`/`P…`.
            .fixedSize()
            .explainable(.panelDensity)   // shared density id (ex-b) — same card on all four panels
        }
    }

    /// The leading cluster's spacing. ⛔ **PRO NEEDS 5, AND THAT WAS MEASURED,
    /// NOT CHOSEN** (TB, 2026-09-25): PANIC (m23-af) and the count-in stepper
    /// (m15-b) arrived after the 340 pt anchor was set, and Pro's content — four
    /// 38 pt buttons, LOOP 46, PUNCH, and the 58 pt CLICK/count-in column — came
    /// to 369 at 10 pt spacing. The anchor squeezed it, and PUNCH, LOOP and CLICK
    /// read `PU…`, `L…`, `CL…` at EVERY window width, 2400 pt included. At 5 pt
    /// the Pro row is 339 and fits with 1 pt to spare; Simple (306 at 10 pt)
    /// keeps its spacing and renders exactly as before. Widening the anchor
    /// instead would have moved Simple's Position/Time 30 pt at every width.
    private var leadingSpacing: CGFloat { isPro ? 5 : 10 }

    private var transportButtons: some View {
        HStack(spacing: leadingSpacing) {
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
            .help(store.transport.isPlaying ? "Pause (space)" : "Play (space)")
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

            // PANIC (m23-af). Momentary, so `isActive` is always false — there is
            // no "panicking" state to show; the press either silenced something
            // or there was nothing to silence, and both look the same.
            //
            // NEVER `.disabled(...)`. The whole point is that a stuck note can
            // outlive any state the app thinks it is in, so every condition you
            // could gate this on is a condition under which it might be the only
            // control that still helps. It is also the reason this sits OUTSIDE
            // the `isPro` check below: a beginner is likelier to hit a stuck note
            // and far likelier to be stuck with it.
            TransportButton(
                systemName: "exclamationmark.octagon.fill",
                isActive: false,
                activeColor: DAWTheme.record
            ) {
                store.panic()
            }
            .help("Panic — silence stuck notes")
            .explainable(.transportPanic)

            loopChip
                .explainable(.transportLoop)

            // Pro-only: PUNCH is an advanced record window. In Simple the chip
            // row closes up naturally (LOOP + CLICK go adjacent) — no placeholder.
            if isPro {
                punchChip
                    .explainable(.transportPunch)
            }

            // CLICK + the count-in stepper as one narrow column (m15-b, the
            // m10-q §1.3 rider): the stepper rides under the chip so the
            // record cluster's measured width budget (the m10-j 340 pt
            // anchor) is untouched — the column is barely wider than the
            // chip and shorter than the 38 pt transport buttons.
            VStack(spacing: 2) {
                clickChip
                    .explainable(.transportClick)
                countInStepper
            }
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
                .fixedSize()
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
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(store.transport.isRecording)  // punch changes are refused mid-take
        .help("Punch recording window")
    }

    /// Toggles the metronome click. Signal green: the click is a healthy
    /// reference signal, not a transport mode. Count-in lives right below in
    /// `countInStepper` (same `transport.setMetronome` verb).
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
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(store.transport.isRecording)  // metronome changes are refused mid-take
        .help("Metronome click")
    }

    /// Count-in bars stepper (m15-b — the audit's thrice-filed m10-q §1.3
    /// rider): exposes the existing `transport.setMetronome countInBars`
    /// setting (0–4 bars, the store clamps). Beginner-readable "IN n" readout
    /// — signal green when armed (count-in is click family; it clicks even
    /// with CLICK off), dim at 0. Disabled mid-take like the chip above
    /// (metronome changes are refused while recording).
    private var countInStepper: some View {
        let bars = store.transport.countInBars
        return HStack(spacing: 3) {
            CountInNudgeButton(label: "−") { setCountInBars(bars - 1) }
                .disabled(bars <= TransportState.countInBarsRange.lowerBound)
            Text("IN \(bars)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(bars > 0 ? DAWTheme.signal : DAWTheme.textDim)
                .frame(minWidth: 24)
                .fixedSize()
            CountInNudgeButton(label: "+") { setCountInBars(bars + 1) }
                .disabled(bars >= TransportState.countInBarsRange.upperBound)
        }
        .disabled(store.transport.isRecording)
        .help("Count-in before recording: 0–4 bars of clicks (they sound even with CLICK off)")
    }

    /// One stepper move: keep the click toggle as-is, set only the bars
    /// (`setMetronome` clamps to `countInBarsRange`).
    private func setCountInBars(_ bars: Int) {
        try? store.setMetronome(enabled: store.transport.isMetronomeEnabled,
                                countInBars: bars)
    }

    private var tempoCluster: some View {
        HStack(spacing: 8) {
            DigitalReadout(
                label: "Tempo",
                // m12-d: the tempo AT THE PLAYHEAD (design row 73) — on a multi-
                // segment map this tracks the active section; on a trivial map it
                // is just the base tempo (byte-identical readout).
                value: String(format: "%.1f", store.transport.tempoMap.bpm(atBeat: store.transport.positionBeats)),
                color: DAWTheme.textPrimary
            )
            VStack(spacing: 3) {
                TempoNudgeButton(label: "+") { nudgeTempo(by: 1) }
                TempoNudgeButton(label: "−") { nudgeTempo(by: -1) }
            }
            .disabled(store.transport.isRecording)  // tempo changes are refused mid-take
        }
    }

    /// Nudge the tempo by ±1 BPM. On a trivial project this is the scalar fast path
    /// (`setTempo`); on a multi-segment map it edits the SEGMENT under the playhead
    /// through `setTempoMap` (design row 73 — the nudge edits the active section),
    /// so the nudge never hits the multi-segment reject.
    private func nudgeTempo(by delta: Double) {
        let map = store.transport.tempoMap
        let position = store.transport.positionBeats
        let current = map.bpm(atBeat: position)
        if store.transport.tempoMapOverride == nil {
            try? store.setTempo(current + delta)
        } else {
            let index = map.segments.lastIndex { $0.startBeat <= position } ?? 0
            var segments = map.segments
            segments[index] = TempoMap.Segment(startBeat: segments[index].startBeat, bpm: current + delta)
            if let updated = try? TempoMap(segments: segments) {
                try? store.setTempoMap(updated)
            }
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
    ///
    /// Collapses to its glyph on a narrow window (TB) — FIRST of the three, since
    /// the share arrow is the one glyph here a beginner already reads as a word.
    private var exportButton: some View {
        ViewThatFits(in: .horizontal) {
            exportChip(compact: false)
            exportChip(compact: true)
        }
    }

    private func exportChip(compact: Bool) -> some View {
        Button { appModel.exportSong() } label: {
            TransportChipFace(systemName: "square.and.arrow.up", word: "EXPORT",
                              compact: compact, ink: DAWTheme.textDim)
        }
        .buttonStyle(.plain)
        .help("Export your song to an audio file")
        .accessibilityLabel("Export")
    }

    /// **THE MODE TOGGLE AND ITS INDICATOR — one control, m23-ct.**
    ///
    /// ⚠️ **THE MODE MUST BE EXPLICIT AND VISIBLY INDICATED, NEVER AMBIENT
    /// CAPTURE.** This project has been bitten by key routing three times (m17-d,
    /// m23-g1, m23-cf) and this mode claims 21 letter keys while it is on. So the
    /// lit state is not decoration: cyan fill + the glow recipe is the app's
    /// "active state" grammar (Rule 3 — an accent is earned by state), and the
    /// piano glyph says WHICH state without needing the word.
    ///
    /// The label stays "KEYS" rather than "MUSICAL TYPING" because the chip row is
    /// a fixed-width neighbourhood; the tooltip and the strip's own header carry
    /// the full name, and the strip appears the instant this is on, so the chip
    /// never has to explain itself alone.
    ///
    /// ⭐ NARROW WINDOWS (TB): the chip gives up its WORD before the bar can cut
    /// it — `TransportChipFace`'s glyph-only form, chosen by `ViewThatFits`
    /// only when the full chip does not fit. The word lives on in the tooltip
    /// and the accessibility label. Its collapse ORDER is `rightRegion`'s.
    private var musicalTypingToggle: some View {
        ViewThatFits(in: .horizontal) {
            musicalTypingChip(compact: false)
            musicalTypingChip(compact: true)
        }
    }

    private func musicalTypingChip(compact: Bool) -> some View {
        let on = appModel.musicalTyping.isEnabled
        return Button { appModel.setMusicalTypingEnabled(!on) } label: {
            TransportChipFace(
                systemName: "pianokeys",
                word: "KEYS",
                compact: compact,
                ink: on ? DAWTheme.playback : DAWTheme.textDim,
                fill: on ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised,
                stroke: on ? DAWTheme.playback.opacity(0.55) : DAWTheme.hairline
            )
            // Glow ONLY while on — earned by state, never static chrome.
            .glow(DAWTheme.playback, radius: on ? 7 : 0, intensity: on ? 0.45 : 0)
        }
        .buttonStyle(.plain)
        .help(on
              ? "Musical Typing is ON — letter keys play notes. Click to turn it off."
              : "Musical Typing: play notes with your computer keyboard and an on-screen piano.")
        .accessibilityLabel("Keys, Musical Typing")
    }

    /// The Pro test tone. `compact` (TB-F1) draws the same round button at the
    /// chip scale — 26 pt, glyph 11 — the cheapest give the fit rule has, since
    /// the control never had a word to lose. Tooltip and label in both forms.
    private func testToneButton(compact: Bool) -> some View {
        TransportButton(
            systemName: "tuningfork",
            isActive: engine.isTonePlaying,
            activeColor: DAWTheme.signal,
            side: compact ? TransportBarFit.chipSide : TransportBarFit.testToneWidth,
            glyphSize: compact ? 11 : 15
        ) {
            if engine.isTonePlaying {
                engine.stopTestTone()
            } else {
                try? engine.startTestTone()
            }
        }
        .help("Test tone (verifies audio output)")
        .accessibilityLabel("Test tone")
    }

    /// The engine-notices chip. Full: `EngineNoticesChip` (amber triangle + the
    /// count of distinct problems), pinned so its count is always drawn. ⭐ **COMPACT (TB-F1): the same amber, the same
    /// glow, the same pressed-in fill while the list is open — without the count.**
    /// The number moves to the tooltip (`chipHelp` already says it) and the
    /// accessibility label, so nothing is lost but its pixels. It is the rule's
    /// second give, before the looper's: a count the popover lists anyway matters
    /// less than a performer's track names. The face is `TransportChipFace`'s
    /// glyph-only square, so it sits in the same family as KEYS and EXPORT.
    @ViewBuilder
    private func noticesChip(compact: Bool) -> some View {
        let model = EngineNoticesModel(notices: store.engineNotices)
        let isOpen = appModel.showEngineNotices
        let toggle = {
            withAnimation(.easeOut(duration: 0.15)) {
                appModel.showEngineNotices.toggle()
            }
        }
        if compact {
            Button(action: toggle) {
                TransportChipFace(systemName: "exclamationmark.triangle.fill",
                                  word: "NOTICES",
                                  compact: true,
                                  ink: DAWTheme.record,
                                  fill: DAWTheme.record.opacity(isOpen ? 0.22 : 0.14),
                                  stroke: DAWTheme.record.opacity(0.6))
                    // Earned by state (Rule 3): the chip only exists while a
                    // real degradation is on record.
                    .glow(DAWTheme.record, radius: 5, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .help(model.chipHelp)
            .accessibilityLabel(model.badgeCount == 1
                                ? "1 playback notice"
                                : "\(model.badgeCount) playback notices")
        } else {
            // ⛔ PINNED AT THE CALL SITE (TB-F1) — A NUMBER NEVER SHRINKS. The
            // shared chip does not pin its own width, and once TB's gaps became
            // flexible SwiftUI offered it less than its width at EVERY window
            // size: the count compressed to nothing and the chip read as a bare
            // triangle (measured 36.5 pt at 1208 and at 1600; 43.5 with its "1"
            // before TB). The room it needs is the fit rule's to find.
            EngineNoticesChip(model: model, isOpen: isOpen, action: toggle)
                .fixedSize()
        }
    }
}

struct TransportButton: View {
    var systemName: String
    var isActive: Bool
    var activeColor: Color
    /// The circle's diameter and glyph size: the transport's 38 / 15, or the
    /// test tone's compact 26 / 11 (TB-F1).
    var side: CGFloat = 38
    var glyphSize: CGFloat = 15
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : DAWTheme.textPrimary)
                .frame(width: side, height: side)
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

/// The face of the transport's glyph-and-word ACTION chips — KEYS, EXPORT and
/// the LOOPER door (`LoopDeckControls`) — in both of its widths (TB, 2026-09-25).
///
/// ⛔ **A LABEL MAY NOT BREAK INSIDE A WORD.** At the 1208 pt window floor the
/// bar used to hand these chips less than their width, and SwiftUI wrapped the
/// words: `KEY`/`S`, `LOO`/`PER`, `EXP`/`ORT`. So the face is PINNED
/// (`.fixedSize()` on the OUTER stack — the m22-g rule: an inner `Text` pin
/// still lets the padding compress), and the room is made a different way:
/// each chip is a `ViewThatFits` of this face `compact: false` then
/// `compact: true`, so on a narrow window it gives up its WORD, whole, and
/// keeps its glyph. The word is never lost — the chip's tooltip and its
/// accessibility label carry it.
///
/// The compact face is SQUARE at the chip's own 26 pt height, the loop deck's
/// `DeckIconButton` scale, so a collapsed chip reads as the same family as the
/// deck's glyph-only controls. A plain value input throughout: the caller
/// owns state colour (`ink`/`fill`/`stroke`) and any glow.
struct TransportChipFace: View {
    var systemName: String
    var word: String
    /// Glyph only — the narrow-window form.
    var compact: Bool
    var ink: Color
    var fill: Color = DAWTheme.panelRaised
    var stroke: Color = DAWTheme.hairline

    /// Side of the glyph-only face — the fit rule's `chipSide`, read rather than
    /// restated so the rule models exactly what this draws (TB-F1).
    static let compactSide: CGFloat = TransportBarFit.chipSide

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
            if !compact {
                Text(word)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, compact ? 0 : 9)
        .frame(width: compact ? Self.compactSide : nil, height: 26)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5).stroke(stroke, lineWidth: 1)
        )
        .fixedSize()
    }
}

/// A gap between two controls in the transport's right region that gives way
/// BEFORE any control does (TB, 2026-09-25). It is the bar's own 20 pt spacing
/// whenever there is room, and closes toward 8 pt as the window narrows; only
/// once every gap is at 8 does an action chip start dropping its word (the
/// chips carry `layoutPriority`, the gaps do not). Zero height, so it can never
/// grow the bar past the 64 pt `WindowFloor.fixedChromeHeight` budgets for it.
///
/// Why 8 and not 10: MEASURED (explain frames, 1208 × 672), Pro's fully
/// compacted right region is 389 pt of controls + 6 gaps in the 443 pt it is
/// given — 449 at 10 pt gaps (over), 437 at 8.
struct TransportGap: View {
    static let full: CGFloat = 20
    static let tightest: CGFloat = 8

    var body: some View {
        Color.clear
            .frame(minWidth: Self.tightest, maxWidth: Self.full, maxHeight: 0)
            .accessibilityHidden(true)
    }
}

/// Micro nudge button for the count-in stepper — the TempoNudgeButton idiom
/// at sub-row scale (the stepper rides UNDER the CLICK chip, so it must stay
/// inside the chip column's height budget).
struct CountInNudgeButton: View {
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 14, height: 11)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 2))
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
