import SwiftUI
import DAWCore
import DAWAppKit

/// **MUSICAL TYPING — the playable on-screen keyboard (m23-ct).** A horizontal
/// piano across the bottom of the window: click it, or type the letter printed on
/// each key, and hear the note. It lights whatever is sounding **whichever surface
/// started it**, so the mouse and the computer keyboard are visibly one instrument
/// rather than two.
///
/// ⭐ **WHY IT EXISTS AT ALL:** this user has no hardware MIDI controller. The
/// whole of `Sources/DAWEngine/MIDIInput/` — a real CoreMIDI client, a UMP parser,
/// an RT-safe thru ring, a capture session — was unreachable for them. The piano
/// roll's `KeyboardSidebar` could sound one note under one mouse pointer, inside
/// the piano roll only. This is the door: polyphonic, typeable, and present
/// against the timeline and the mixer alike.
///
/// ═══ THE SECOND LIGHT SURFACE, AND WHY IT IS ALLOWED TO BE ONE ═══
///
/// `DAWTheme`'s key-row comment and docs/DESIGN-LANGUAGE.md both used to say the
/// piano-roll gutter was "the app's ONE light surface (m23-b)". **This is the
/// second, and both docs are updated rather than quietly contradicted.** The rule
/// m23-b actually established was never "exactly one light surface" — it was *a
/// light surface earns its own measured ink, it never borrows the dark
/// hierarchy*. An ivory piano key is the ONE object in a DAW that is ivory in the
/// world, so a second one is the rule being obeyed, not bent. This view reuses
/// `keyWhite` / `keyBlack` / `keyEdgeOnWhite` / `keyLabelOnWhite` verbatim — it
/// invents no palette and carries no raw hex.
///
/// ═══ CANVAS, AND WHAT IT COSTS PER FRAME ═══
///
/// One `Canvas` (docs/DESIGN-LANGUAGE.md "Meters": custom-drawn, no per-frame
/// allocation). The renderer is `@Sendable` (the m16-a contract), so everything it
/// touches is snapshotted into a value BEFORE the closure — the geometry, the
/// sounding set, and the pitch→letter table. It redraws only when one of those
/// changes: this view reads no transport clock and mounts no `TimelineView`, so a
/// running transport does not tick it.
struct MusicalKeyboardStrip: View {
    /// The one live ledger — mode, octave, velocity, and what is sounding. A
    /// plain value input (an `@Observable` object), so a preview drives it with a
    /// bare `MusicalTypingController()` exactly as the app does.
    var controller: MusicalTypingController
    /// Turns the mode off. Held by the app so the toggle in the transport bar and
    /// the button here drive the SAME funnel.
    var onClose: () -> Void = {}
    /// A key was pressed WITH THE MOUSE.
    ///
    /// ⛔ **THIS EXISTS SO THE MOUSE AND THE STAGING SEAM RUN THE SAME CODE.**
    /// `debug.musicalTyping`'s `pointerPitch` refreshes the target state before it
    /// sounds, because a click can be the first thing that happens after the user
    /// changed tracks. If this view called `controller.pointerDown` directly, the
    /// seam would drive a slightly DIFFERENT path than the mouse — the m23-an
    /// class of defect, where a gate is green on a path no human takes. The app
    /// hands both the same closure; the default keeps a bare preview playable.
    var onPointerPress: (Int) -> Void = { _ in }
    /// A CHORD CELL was pressed with the mouse — the chord row's half of
    /// `onPointerPress`, carrying a cell index rather than a pitch.
    ///
    /// ⛔ **SAME REASON, SAME SHAPE.** The app hands both this and `onPointerPress`
    /// the closures that refresh the target state first, so the mouse and
    /// `debug.musicalTyping` drive one path. A view that called
    /// `controller.pointerDown(cellIndex:)` directly would be the m23-an defect in
    /// a new mode.
    var onChordCellPress: (Int) -> Void = { _ in }
    /// **THE SUSTAIN PEDAL (m34-l), toggled WITH THE MOUSE.**
    ///
    /// ⛔ **SAME ONE-FUNNEL REASON AS `onPointerPress`.** The app hands in the
    /// closure that refreshes the target state first, so the pedal pill, the Tab
    /// key and `debug.musicalTyping {sustain:}` all end in one `setSustain`. A
    /// view calling `controller.toggleSustain()` directly would judge the press
    /// against a stale target state — the m23-an defect, on a new control.
    ///
    /// ⭐ It also gives the pedal a MOUSE route, which matters more here than
    /// for the note keys: Tab is the one binding in this mode that a user might
    /// reasonably expect to move focus, so there has to be a way to work the
    /// pedal without pressing it.
    var onToggleSustain: () -> Void = {}
    /// Turns chord mode on and off.
    var onSetPlayMode: (MusicalTypingPlayMode) -> Void = { _ in }
    /// Sets the tonic (pitch class) and, optionally, the scale.
    var onSetKey: (Int, KeyMode?) -> Void = { _, _ in }
    /// Sets the instrument voicing style.
    var onSetVoicingPreset: (VoicingPresetKind) -> Void = { _ in }
    /// Lights a named progression, or clears the lights with nil.
    var onSetProgression: (ChordProgressionPreset?) -> Void = { _ in }
    /// **PLAYBOX (m34-g): chooses WHEN the outline moves.** Wait-for-you,
    /// on-the-beat, or lights-run-ahead — the user asked for all three.
    var onSetAdvanceMode: (ChordSequenceAdvanceMode) -> Void = { _ in }
    /// **PLAYBOX: generate a fresh set of lights** from the project's own key,
    /// tempo and section. ⛔ It lights keys; it plays nothing.
    var onGeneratePlaybox: () -> Void = {}
    /// True while a generation is in flight — the button dims.
    var isGeneratingPlaybox: Bool = false

    // ── m39-pads: the THIRD face. ────────────────────────────────────────────
    /// The pad grid's live model, or nil in a bare preview (the PADS chip then
    /// still switches mode and the face draws an empty grid, which is honest —
    /// a preview has no sampler).
    var padGrid: PadGridModel?
    /// A PAD was struck with the mouse: index in the current bank, and where in
    /// the pad (0 = top edge).
    ///
    /// ⛔ **SAME ONE-FUNNEL REASON AS `onPointerPress`** — the app hands in the
    /// closure that refreshes the target state first, so the mouse and
    /// `debug.padGrid` run one path and a gate cannot be green on a route no
    /// human takes.
    var onPadPress: (Int, Double) -> Void = { _, _ in }
    var onPadRelease: () -> Void = {}
    var onSetBank: (Int) -> Void = { _ in }
    /// Opens the CHOP TO PADS card.
    var onOpenChop: () -> Void = {}

    /// Keyboard height. Tall enough for a black key (62 %) to be a comfortable
    /// mouse target and for the letter legend to sit under it without crowding.
    private static let keyboardHeight: CGFloat = 64

    /// The legend's ink on a HELD key, decided once from the measured crossover
    /// rather than picked. `NotePillInk` is the app's ONE home for "what can be
    /// read on a variable-luminance surface"; cyan over ivory is bright, so this
    /// resolves to the dark ink — but it is derived so it cannot go stale if the
    /// accent ever moves.
    private static let heldInkIsDark = NotePillInk.prefersDarkInk(
        tint: SRGBColor(hex: DAWTheme.playbackHex),
        alpha: 1.0,
        backdrop: SRGBColor(hex: DAWTheme.keyWhiteHex))

    /// Chord-row height. Three stacked labels (key letter, chord name, Roman
    /// numeral) plus clear air at the bottom of the cell need more room than a
    /// piano key's single legend.
    ///
    /// ⚠️ **THE FOURTH LABEL IS GONE AND THE HEIGHT DELIBERATELY STAYED (m34-i).**
    /// It used to read "four stacked labels … order badge"; the badge was deleted
    /// and the room it held now goes to the next-chord outline's bloom, which
    /// needs to read as a halo rather than as a hairline.
    private static let chordRowHeight: CGFloat = 76

    private var isChordMode: Bool { controller.playMode == .chords }
    /// m39-pads. ⚠️ **A THIRD FACE, NOT A SECOND BOOLEAN READ AS A NEGATION.**
    /// Every `!isChordMode` in this file used to mean "the piano"; it now means
    /// "not the chord row", which is two different faces. Each site was re-read
    /// rather than left to fall through — the m39-e shape, where a third case
    /// quietly inherited a two-case answer and 24 tests stayed green over an
    /// inert feature.
    private var isPadMode: Bool { controller.playMode == .pads }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // ⭐ **ONE SURFACE, TWO FACES — AND THE PIANO IS NOT RELABELLED, IT IS
            // REPLACED.** In chord mode a key no longer names a pitch: which
            // pitches it sounds depends on the scale, the preset and the voicing
            // before it. Drawing a piano and writing chord names on it would be a
            // picture that lies about what a click does — the ivory C would sound
            // a four-note chord that is not, in general, a C. So chord mode gets
            // its own row of cells, drawn by the same Canvas with the same theme
            // tokens and the same legend-drawing shape.
            if isChordMode {
                chordPickers
                progressionRow
                playboxRow
                chordRow
            } else if isPadMode {
                // ⭐ THE SAME ARGUMENT ONE FACE FURTHER ON. In pads mode a key
                // does not name a pitch on a keyboard either — it names a SLICE
                // of a record, and which slice depends on the bank. Drawing a
                // piano and writing slice numbers on it would be the same
                // picture-that-lies the chord row was split out to avoid.
                padFace
            } else {
                keyboard
            }
            legend
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 18) {
            // The mode lamp. Cyan + glow only while it can actually sound —
            // "glow is earned by state, never static chrome" (Rule 3 / the glow
            // recipe). When it cannot, it goes amber, which is the accent
            // system's warning hue, and the line beside it says why.
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .glow(statusColor, radius: 6, intensity: canSound ? 0.7 : 0.4)
                Text("MUSICAL TYPING")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(DAWTheme.textPrimary)
                // ⭐ THE HONESTY LIGHT. Present ONLY while this performance is
                // actually being kept — the one piece of information the user
                // cannot get by ear, because a take that records nothing sounds
                // exactly like a take that records everything. It takes `record`
                // red and the glow recipe, matching the transport's own record
                // button so the two cannot be read as different states.
                if isCapturing {
                    Text("● RECORDING")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(DAWTheme.record)
                        .glow(DAWTheme.record, radius: 5, intensity: 0.7)
                        .accessibilityLabel("Recording what you play")
                }
            }

            // ⭐⭐ **THE PEDAL LAMP (m34-l) — STATE AS LIGHT, NEVER AS TEXT.**
            // A performer cannot read while playing, so the word "SUSTAIN" is
            // static chrome (exactly like "MUSICAL TYPING" beside it) and the
            // only thing that MOVES is the light: filled + glowing when the
            // damper is off the strings, a bare outline when it is down on them.
            // The same law that deleted m34-i's numeric badges.
            //
            // ⚠️ `.fixedSize()` because the status line beside it is a long
            // sentence with `.lineLimit(1)`: without it SwiftUI compresses the
            // pill instead of truncating the sentence, and the indicator
            // vanishes exactly when the status line is longest.
            sustainPill.fixedSize()

            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(canSound ? DAWTheme.textSecondary : DAWTheme.record)
                .lineLimit(1)

            Spacer(minLength: 12)

            // ⭐ THE MODE SWITCH. Two chips rather than a toggle, so the state is
            // readable at a glance instead of inferred from a switch position —
            // the same "explicit, never ambient" law the mode lamp obeys.
            HStack(spacing: 0) {
                modeChip("KEYS", isOn: !isChordMode && !isPadMode) { onSetPlayMode(.notes) }
                modeChip("CHORDS", isOn: isChordMode) { onSetPlayMode(.chords) }
                modeChip("PADS", isOn: isPadMode) { onSetPlayMode(.pads) }
            }
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))

            // SF Mono for every numeric readout (docs/DESIGN-LANGUAGE.md
            // "Foundations"). OCTAVE reads as the note the `A` key sounds rather
            // than as a bare number — Rule 6: a beginner should not have to know
            // what "octave 4" means to find the note they just played.
            // ⚠️ **THE READOUT SAYS WHAT Z/X ACTUALLY MOVE.** In pads mode they
            // move the BANK, so a readout still labelled "Octave" would be a
            // number nothing on screen responds to — the m39-e shape in a
            // label. One readout, three truths.
            if isPadMode {
                DigitalReadout(label: "Pads", value: padRangeValue,
                               color: DAWTheme.playback, valueSize: 15)
            } else {
                DigitalReadout(label: "Octave", value: octaveValue,
                               color: DAWTheme.playback, valueSize: 15)
            }
            DigitalReadout(label: "Velocity", value: String(controller.velocity),
                           color: DAWTheme.playback, valueSize: 15)

            Button(action: onClose) {
                Text("TURN OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(height: 20)
                    .padding(.horizontal, 9)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Stop capturing letter keys as notes.")
        }
    }

    /// **THE SUSTAIN PEDAL'S LAMP AND ITS MOUSE TARGET, in one control.**
    ///
    /// ⚠️ **GREEN (`signal`), NOT CYAN (`playback`), AND THE CHOICE IS ABOUT
    /// AMBIGUITY RATHER THAN TASTE.** The mode lamp two elements to the left is
    /// already cyan; a second cyan lamp on the same row would read as a second
    /// copy of the same state. `signal` is the palette's "this is engaged and
    /// healthy" hue, it is not `record` (warning) or `clip` (destructive) —
    /// neither of which a pedal is — and it is a token, never a new colour.
    ///
    /// ⚠️ **DIMMED WHEN THE KEYS CANNOT SOUND**, so the control never invites a
    /// press that `setSustain` would refuse: the pedal has nothing to hold when
    /// there is no instrument under it.
    private var sustainPill: some View {
        Button(action: onToggleSustain) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isSustainDown ? DAWTheme.signal : Color.clear)
                    .overlay(Circle().stroke(
                        isSustainDown ? DAWTheme.signal : DAWTheme.textFaint,
                        lineWidth: 1))
                    .frame(width: 7, height: 7)
                    // Glow is EARNED BY STATE, never static chrome (Rule 3).
                    .glow(DAWTheme.signal, radius: 6,
                          intensity: isSustainDown ? 0.8 : 0)
                Text("⇥ SUSTAIN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(isSustainDown ? DAWTheme.signal : DAWTheme.textDim)
            }
            .frame(height: 20)
            .padding(.horizontal, 9)
            .background(isSustainDown
                        ? DAWTheme.signal.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                isSustainDown ? DAWTheme.signal.opacity(0.55) : DAWTheme.hairline,
                lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(canSound ? 1 : 0.45)
        .help("Sustain pedal (Tab) — keeps notes ringing after you lift the key, "
              + "like the right pedal on a piano. Press again to let go.")
        .accessibilityLabel(isSustainDown ? "Sustain pedal down" : "Sustain pedal up")
    }

    private var isSustainDown: Bool { controller.isSustainDown }

    /// ⛔ **`canSound`, NOT `== .ready`** — both recording states sound. Reading
    /// `.ready` here would drop the lamp to amber and the status line to red at
    /// exactly the moment the user IS successfully recording.
    private var canSound: Bool { controller.targetState.canSound }
    /// Whether the app believes this performance is being kept.
    private var isCapturing: Bool { controller.targetState.isCapturing }
    /// ⚠️ **THREE OUTCOMES, THREE HUES, AND THE MIDDLE ONE IS THE POINT.**
    ///
    /// - **Cyan** (`playback`) — playing normally, and that includes recording
    ///   successfully: the keys work and the notes are being kept.
    /// - **Red** (`clip`, the destructive hue) — `recordingUnarmed`. This is the
    ///   only state in the app where everything looks and SOUNDS correct while
    ///   the user's performance is being thrown away, so it gets the strongest
    ///   signal in the palette. It is deliberately louder than the refusals
    ///   below it: a refusal costs you nothing, this costs you a take.
    /// - **Amber** (`record`, the warning hue) — a genuine refusal. Unchanged
    ///   from before the engine half landed.
    private var statusColor: Color {
        switch controller.targetState {
        case .ready, .recordingArmed: return DAWTheme.playback
        case .recordingUnarmed: return DAWTheme.clip
        case .noTrack, .notInstrument, .previewOff: return DAWTheme.record
        }
    }

    /// Beginner-readable, one line, and it always names the FIX rather than the
    /// fault (Rule 6). These are the only words a user gets when a key makes no
    /// sound, so "not ready" is never one of them.
    private var statusLine: String {
        switch controller.targetState {
        case .ready:
            return "Type the letters on the keys, or click them, to play."
        case .noTrack:
            return "Pick an instrument track first — click one in the track list."
        case .notInstrument:
            return "This track has no instrument to play. Pick an instrument track."
        case .recordingArmed:
            // Says what is HAPPENING, present tense, because it is true — the
            // notes are going into the take as they are played.
            return "Recording — everything you play is going into the take."
        case .recordingUnarmed:
            // ⛔ THE FOOTGUN LINE. Captured MIDI fans out to ARMED instrument
            // tracks only, so playing an un-armed one during a take sounds
            // completely normal and keeps nothing. Names the FIX (arm it) rather
            // than the fault, per Rule 6.
            return "You'll hear this, but it won't be recorded — arm this track (R) first."
        case .previewOff:
            return "Note preview is switched off, so nothing will sound."
        }
    }

    private var octaveValue: String {
        Fundamental.noteName(midiNote: controller.baseNote)
    }

    /// Which sixteen pads are under the hand, 1-based and inclusive — the
    /// question a performer asks ("am I on the kick bank or the perc bank?"),
    /// not the 0-based bank index the code carries.
    private var padRangeValue: String {
        let first = controller.padBank * PadGridGeometry.padsPerBank + 1
        return "\(first)–\(first + PadGridGeometry.padsPerBank - 1)"
    }

    // MARK: - The pad face (m39-pads)

    /// ⚠️ **THE GRID IS DRAWN FROM THE MODEL'S `pads`, NOT FROM THE
    /// CONTROLLER.** The controller knows what is SOUNDING; only the model
    /// knows which pads carry a slice. Drawing from the controller alone would
    /// produce a grid where every square looked identical — the exact "cannot
    /// tell loaded from empty" surface this item exists to avoid.
    @ViewBuilder
    private var padFace: some View {
        if let padGrid {
            VStack(alignment: .leading, spacing: 9) {
                padFaceHeader(padGrid)
                PadGridView(
                    pads: padGrid.pads,
                    bank: padGrid.bank,
                    bankCount: padGrid.bankCount,
                    frameSpan: padGrid.loadedFrameSpan,
                    canSound: canSound,
                    triggerMode: padGrid.triggerMode,
                    triggerModeError: padGrid.lastTriggerModeError,
                    triggerModeUnavailableReason: padGrid.triggerModeUnavailableReason,
                    onPadDown: onPadPress,
                    onPadUp: onPadRelease,
                    onSetBank: onSetBank,
                    onSetTriggerMode: { padGrid.setTriggerMode($0) },
                    isLevels: padGrid.isLevels,
                    levelsArming: padGrid.levelsArming,
                    levelsStatus: padGrid.levelsStatus,
                    levelsUnavailableReason: padGrid.levelsUnavailableReason,
                    levelsError: padGrid.lastLevelsError,
                    onToggleLevels: { padGrid.toggleLevels() })
                if let notice = padGrid.lastChop {
                    chopNotice(notice, model: padGrid)
                }
            }
        } else {
            // A preview with no model. Says so rather than drawing a dead grid.
            Text("No instrument selected — pick a track to see its pads.")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textFaint)
                .frame(height: 220)
        }
    }

    private func padFaceHeader(_ padGrid: PadGridModel) -> some View {
        HStack(spacing: 12) {
            // ⭐ LOADED vs TOTAL, ALWAYS — "a pad grid where you cannot tell
            // loaded from empty is not usable" applies to the SUMMARY as much
            // as to the squares. SF Mono, because it is a count.
            Text("\(padGrid.loadedCount)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(padGrid.loadedCount > 0
                                 ? DAWTheme.playback : DAWTheme.textFaint)
            Text(padGrid.loadedCount == 1 ? "slice loaded" : "slices loaded")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textSecondary)
            if let name = padGrid.targetName {
                Text("on \(name)")
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
            }
            // ⭐ THE UNREACHABLE-SLICE REPORT. A keymap based below pad 1 draws
            // sixteen empty squares over a fully loaded sampler, and every other
            // reading agrees with the picture. Say it, and offer the one-click
            // fix rather than making the user find the base note.
            if padGrid.unreachableBelowCount > 0 {
                Button { padGrid.baseOnLowestSlice() } label: {
                    Text("\(padGrid.unreachableBelowCount) below pad 1 — show them")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DAWTheme.record)
                }
                .buttonStyle(.plain)
                .help("This kit has slices under the grid's first pad. Re-base the grid "
                      + "on the lowest one.")
            }
            Spacer(minLength: 8)
            Button(action: onOpenChop) {
                Text("CHOP A CLIP…")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    // Create/add affordances are NEUTRAL CHROME (Rule 3) — no
                    // accent and no glow at rest. An accent is earned by state,
                    // not by inviting a click.
                    .foregroundStyle(DAWTheme.textPrimary)
                    .frame(height: 22)
                    .padding(.horizontal, 12)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Cut the selected audio clip into pads you can play.")
        }
    }

    /// What the chop just did, and what it muted. ⚠️ Stays up until dismissed:
    /// it reports an action with a SIDE EFFECT on another track, which is not
    /// something to flash past the corner of the eye.
    private func chopNotice(_ notice: PadChopSummary, model: PadGridModel) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.signal)
            VStack(alignment: .leading, spacing: 3) {
                Text(chopNoticeText(notice))
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(notice.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.system(size: 10))
                        .foregroundStyle(DAWTheme.record)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button { model.dismissChopNotice() } label: {
                Text("GOT IT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func chopNoticeText(_ notice: PadChopSummary) -> String {
        var text = "\(notice.sliceCount) pad\(notice.sliceCount == 1 ? "" : "s") on "
            + "“\(notice.trackName)”\(notice.createdTrack ? " (a new track)" : "")."
        // ⚠️⚠️ **TWO INDEPENDENT FACTS, TWO SENTENCES — and collapsing them into
        // one `if/else` is the bug this shape exists to prevent.** "Did THIS
        // chop mute something?" (undo messaging) and "will the original be
        // heard?" (what you are about to listen to) are different questions with
        // four combinations, not two: a track that was ALREADY muted gets no
        // mute from this call and is still inaudible, and a chop onto the
        // source's own track gets no mute and IS audible. Both readings come
        // from the store, never from what the card asked for.
        if let muted = notice.mutedTrackName {
            text += " “\(muted)” was muted so the original does not play under the pads "
                + "— unmute it in the track list whenever you like."
        }
        if notice.sourceStillAudible {
            // THE HONESTY BRANCH. Not muting is a legitimate choice, and the
            // user who made it must be told what they will hear rather than
            // left to diagnose a comb filter by ear.
            text += " The original is still playing underneath — mute its track "
                + "if the two sound hollow together."
        }
        return text
    }

    // MARK: - The keys

    private var keyboard: some View {
        // CANVAS CONTRACT (m16-a): the renderer closure is @Sendable — every
        // capture below is a VALUE, computed here rather than read from the
        // controller inside the closure.
        let span = controller.pitchSpan
        let sounding = controller.soundingPitchSet
        // pitch → the letter a user would type for it, so the two surfaces teach
        // each other. Built from `MusicalTypingRouting.noteCaps` — the ONE layout
        // table — never from a second list here.
        let legends: [Int: String] = Dictionary(
            uniqueKeysWithValues: MusicalTypingRouting.noteCaps.compactMap { cap in
                cap.semitone.map { (controller.baseNote + $0, cap.label) }
            })
        let heldInk = Self.heldInkIsDark ? DAWTheme.noteInkOnLight : DAWTheme.noteInkOnDark
        return Canvas { @Sendable context, size in
            let geometry = MusicalKeyboardGeometry(pitches: span, size: size)
            // Naturals first, accidentals second: the blacks are drawn ON TOP,
            // the way they sit on a piano and the way `pitch(atX:y:)` hit-tests
            // them. Reversing these two loops would leave every accidental
            // half-buried under its neighbour.
            for pitch in geometry.whitePitches {
                guard let rect = geometry.rect(forPitch: pitch) else { continue }
                let held = sounding.contains(pitch)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(held ? DAWTheme.playback : DAWTheme.keyWhite))
                // The seam with the key to the left. On the two all-ivory seams
                // (E|F and B|C) it is the only thing that makes them read as two
                // keys — `KeyboardSidebar`'s finding, in the other axis.
                context.fill(
                    Path(CGRect(x: rect.minX, y: 0, width: 0.5, height: rect.height)),
                    with: .color(DAWTheme.keyEdgeOnWhite))
                Self.drawLegend(&context, rect: rect, pitch: pitch,
                                letter: legends[pitch], held: held,
                                onBlackKey: false, heldInk: heldInk)
            }
            for pitch in geometry.pitches where MusicalKeyboardGeometry.isBlackKey(pitch) {
                guard let rect = geometry.rect(forPitch: pitch) else { continue }
                let held = sounding.contains(pitch)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(held ? DAWTheme.playback : DAWTheme.keyBlack))
                Self.drawLegend(&context, rect: rect, pitch: pitch,
                                letter: legends[pitch], held: held,
                                onBlackKey: true, heldInk: heldInk)
            }
        }
        .frame(height: Self.keyboardHeight)
        // The width the keys were ACTUALLY laid out at, read back for the
        // gesture's hit test. See `keyboardWidth`.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { keyboardWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in keyboardWidth = width }
            }
        )
        .contentShape(Rectangle())      // a Canvas has no hit shape of its own
        .gesture(keyPress)
    }

    // MARK: - The chord row

    /// 17 cells, one per layout key, in the physical left-to-right order the keys
    /// sit in. Same `Canvas`, same `@Sendable` contract, same theme tokens as the
    /// piano above it — everything is snapshotted into values BEFORE the closure.
    ///
    /// ⭐ **FOUR STATES, ONE HUE, FOUR INTENSITIES**, which is the research's own
    /// instruction (§7.4: *"reusing the strip's existing held/lit visual language
    /// at a lower intensity"*) and keeps the palette semantic:
    ///
    ///   * **Sounding** — solid `playback` + glow. Identical to a held piano key,
    ///     because it means the same thing.
    ///   * **NEXT in the progression (m34-i)** — the lit wash, brighter, inside a
    ///     heavy `playback` outline with the house glow recipe's bloom. **This is
    ///     the moving cue that replaced the numeric order badges**, and it is the
    ///     only thing on this row that changes as you play.
    ///   * **Lit by the preset** — a thin `playback` outline and a faint wash.
    ///     Visibly suggested, audibly nothing.
    ///   * **Dim** — `panelRaised`. **Fully playable**, and the legend under the
    ///     row says so in words.
    private var chordRow: some View {
        let cells = controller.chordCells
        let sounding = controller.soundingChordKeyCodes
        let heldInk = Self.heldInkIsDark ? DAWTheme.noteInkOnLight : DAWTheme.noteInkOnDark
        return Canvas { @Sendable context, size in
            guard !cells.isEmpty else { return }
            let width = size.width / CGFloat(cells.count)
            for (index, cell) in cells.enumerated() {
                let rect = CGRect(x: CGFloat(index) * width + 1, y: 0,
                                  width: max(1, width - 2), height: size.height)
                Self.drawChordCell(&context, rect: rect, cell: cell,
                                   isSounding: sounding.contains(cell.keyCode),
                                   heldInk: heldInk)
            }
        }
        .frame(height: Self.chordRowHeight)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { keyboardWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in keyboardWidth = width }
            }
        )
        .contentShape(Rectangle())
        .gesture(chordCellPress(cellCount: cells.count))
    }

    /// One cell. Kept `nonisolated static` for the same reason `drawLegend` is:
    /// the `Canvas` renderer is `@Sendable`.
    private nonisolated static func drawChordCell(_ context: inout GraphicsContext,
                                                  rect: CGRect,
                                                  cell: MusicalTypingChordCell,
                                                  isSounding: Bool,
                                                  heldInk: Color) {
        let shape = Path(roundedRect: rect, cornerRadius: 4)
        if isSounding {
            context.fill(shape, with: .color(DAWTheme.playback))
        } else {
            // A COLOUR key (the accidental row) is drawn recessed, the way a black
            // key is — it is the secondary row on the physical keyboard too.
            context.fill(shape, with: .color(cell.addsColour
                                             ? DAWTheme.panel : DAWTheme.panelRaised))
            if cell.isLit {
                // The NEXT cell takes a brighter wash so it reads at a glance
                // from across the room, not only at the border.
                context.fill(shape, with: .color(
                    DAWTheme.playback.opacity(cell.isNextInProgression ? 0.24 : 0.14)))
                context.stroke(shape, with: .color(DAWTheme.playback.opacity(0.75)),
                               lineWidth: 1.5)
            } else {
                context.stroke(shape, with: .color(DAWTheme.hairline), lineWidth: 1)
            }
        }

        // ⭐⭐ **THE NEXT-CHORD BORDER (m34-i) — THE USER'S OWN PROPOSAL, AND IT
        // IS THE WHOLE FEATURE.** *"it is better to light up border on then next
        // recommeded chord."* Exactly one cell wears it while a preset is lit
        // (`MusicalTypingChordCell.isNextInProgression` pins the count), and it
        // MOVES as the sequence advances — which is what makes Four Chords,
        // Doo-Wop and Pop-Punk tell each other apart at all: they light the same
        // four degrees and differ only in order.
        //
        // ⚠️ **THE INK FLIPS ON A SOUNDING CELL, AND THAT IS NOT COSMETIC.**
        // Cyan-on-cyan is invisible. Today `.onMatch` moves the border OFF the
        // cell you just played so the overlap is rare — but m34-g's on-the-beat
        // mode advances the cue onto a chord you are still holding, and that is
        // a state no capture in this repo can easily stage. Handled now rather
        // than discovered then.
        //
        // ⚠️ **NO `.glow()` HERE — IT IS A VIEW MODIFIER AND THIS IS A `Canvas`
        // RENDERER.** The house recipe (docs/DESIGN-LANGUAGE.md "Foundations":
        // full-opacity core + tight halo + faint wide bloom) is reproduced with
        // layered strokes, the `StereoScopeView` pattern. The path is INSET so
        // the 6 pt bloom stays inside the 2 pt gutter between cells instead of
        // bleeding onto the neighbour.
        if cell.isNextInProgression {
            let ink: Color = isSounding ? heldInk : DAWTheme.playback
            let border = Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 3)
            context.stroke(border, with: .color(ink.opacity(0.18)), lineWidth: 6)
            context.stroke(border, with: .color(ink.opacity(0.50)), lineWidth: 3.5)
            context.stroke(border, with: .color(ink), lineWidth: 2)
        }

        // ⭐⭐⭐ **THE LOOK-AHEAD QUEUE (m34-g) — AND IT CLOSES A DEFECT m34-i
        // COULD ONLY STATE.** Four Chords `[1,5,6,4]` and Doo-Wop `[1,6,4,5]`
        // light the same four degrees AND BOTH OPEN ON I, so with only a moving
        // border two of the three presets still looked identical *at rest*. The
        // queue is what tells them apart before a note is struck: the same four
        // cells, in two different orders.
        //
        // ⛔⛔ **A SHRINKING BAR, NOT A NUMBER. STATE IS SHOWN BY LIGHT, NEVER BY
        // TEXT** (docs/DESIGN-LANGUAGE.md) — a performer cannot read while
        // playing, and a rank drawn as a digit is precisely the badge m34-i
        // deleted for being unreadable. The order is carried by TWO redundant
        // channels so it survives a glance: **width** (3/4, 2/4, 1/4 of the
        // cell) and **brightness**. Nearer means wider and brighter.
        //
        // ⚠️ It sits in the bottom gutter the deleted badge freed, BELOW the
        // "+8va" legend, so it never collides with a glyph.
        if let rank = cell.queueRank {
            let steps = CGFloat(MusicalTypingController.queueDepth + 1)
            let remaining = max(1, steps - CGFloat(rank))
            let inner = rect.insetBy(dx: 6, dy: 0)
            let barWidth = inner.width * (remaining / steps)
            let bar = Path(roundedRect: CGRect(x: rect.midX - barWidth / 2,
                                               y: rect.maxY - 6,
                                               width: barWidth, height: 3),
                           cornerRadius: 1.5)
            let ink: Color = isSounding ? heldInk : DAWTheme.playback
            context.fill(bar, with: .color(ink.opacity(0.20 + 0.22 * (remaining / steps))))
        }

        let primary: Color = isSounding ? heldInk
            : (cell.isLit ? DAWTheme.textPrimary : DAWTheme.textSecondary)
        let secondary: Color = isSounding ? heldInk
            : (cell.isLit ? DAWTheme.textSecondary : DAWTheme.textDim)

        // The key to press — the one thing this surface exists to answer.
        context.draw(
            Text(cell.keyLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(secondary),
            at: CGPoint(x: rect.midX, y: rect.minY + 10), anchor: .center)
        // What it is called.
        context.draw(
            Text(cell.chordName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary),
            at: CGPoint(x: rect.midX, y: rect.minY + 28), anchor: .center)
        // What it IS — the Roman numeral, which is the part that teaches.
        context.draw(
            Text(cell.romanNumeral)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(secondary),
            at: CGPoint(x: rect.midX, y: rect.minY + 44), anchor: .center)
        // ⛔⛔ **THE ORDER BADGE USED TO BE DRAWN HERE AND IS DELETED (m34-i).**
        // The user played the shipped build and reported the numbers were *"hard
        // to read"* — and the same pass exposed what they were papering over: the
        // three same-set presets were told apart by nothing else. **State is
        // shown by LIGHT, never by text; a performer cannot read while playing.**
        // The border above is the replacement. `cell.progressionOrder` survives
        // as seam data only — if you are about to draw it again, read its doc
        // first.
        if cell.octaveShift > 0 {
            // The second run of degrees, marked so a user can tell it from the
            // first rather than wondering why two keys say the same thing.
            //
            // ⚠️ This used to be the `else` of the badge branch, so it was
            // suppressed on any numbered cell — harmless then (a numbered cell is
            // always `octaveShift == 0`), and unconditional now that the badge is
            // gone, which is what it always meant.
            context.draw(
                Text("+8va")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(isSounding ? heldInk.opacity(0.7) : DAWTheme.textFaint),
                at: CGPoint(x: rect.midX, y: rect.maxY - 12), anchor: .center)
        }
    }

    /// Press-and-hold on the chord row, `keyPress`'s contract exactly: a plain
    /// click sounds immediately and sliding across cells moves the chord, because
    /// the controller diffs.
    private func chordCellPress(cellCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard cellCount > 0, keyboardWidth > 0 else { return }
                let index = Int(value.location.x / (keyboardWidth / CGFloat(cellCount)))
                guard index >= 0, index < cellCount else { return }
                onChordCellPress(index)
            }
            .onEnded { _ in controller.pointerUp() }
    }

    /// The letter to type, and — on a C — the note's name.
    ///
    /// DUAL INK, per key, exactly as the gutter does it: the polarity comes from
    /// the key this glyph sits on. `keyLabelOnWhite` on an ivory key (10.1:1),
    /// `textDim` on a black one (5.97:1), and on a HELD key the measured
    /// `NotePillInk` answer for the cyan it is now filled with. Reaching for the
    /// dark hierarchy on ivory is the silent-disappearance defect m23-b closed.
    private nonisolated static func drawLegend(_ context: inout GraphicsContext,
                                               rect: CGRect, pitch: Int,
                                               letter: String?, held: Bool,
                                               onBlackKey: Bool, heldInk: Color) {
        let ink: Color = held ? heldInk
            : (onBlackKey ? DAWTheme.textDim : DAWTheme.keyLabelOnWhite)
        if let letter {
            context.draw(
                Text(letter)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(ink),
                at: CGPoint(x: rect.midX, y: rect.maxY - 11), anchor: .center)
        }
        // Octave landmarks only. Every key carries its LETTER (that is what this
        // surface is for); naming all 17 pitches as well would be two labels per
        // key on a 64 pt strip. The gutter next door names every pitch and is the
        // place to read them — this one answers "which key do I press".
        if pitch % 12 == 0, !onBlackKey {
            context.draw(
                Text(Fundamental.noteName(midiNote: pitch))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(ink),
                at: CGPoint(x: rect.midX, y: rect.maxY - 24), anchor: .center)
        }
    }

    /// Press-and-hold, `KeyboardSidebar`'s contract exactly: `minimumDistance: 0`
    /// so a plain click sounds immediately, and sliding across keys glissandos for
    /// free because the controller diffs (one pointer is one note; chords come
    /// from typing, or from clicking on top of held keys).
    private var keyPress: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let geometry = MusicalKeyboardGeometry(
                    pitches: controller.pitchSpan,
                    size: CGSize(width: keyboardWidth, height: Self.keyboardHeight))
                guard let pitch = geometry.pitch(atX: value.location.x,
                                                 y: value.location.y) else { return }
                onPointerPress(pitch)
            }
            .onEnded { _ in controller.pointerUp() }
    }

    /// The Canvas's own width, reported by its renderer, so the gesture hit-tests
    /// against the size the keys were actually DRAWN at.
    ///
    /// ⚠️ A gesture that recomputed geometry from a guessed width would be the
    /// m23-o2 `widthSource` failure — it would agree with itself while the keys
    /// were somewhere else. `GeometryReader` is the source, not a constant.
    @State private var keyboardWidth: CGFloat = 0

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 14) {
            // ⚠️ THREE FACES, THREE MEANINGS — and in pads mode the CONTROL
            // KEYS THEMSELVES MOVE, not just their meaning: `Z X C V` become
            // pads 1-4 of the spatial block, so bank and velocity relocate to
            // `K / L` and `O / P`. A legend that still said "Z / X octave"
            // would name keys that now play drums.
            if isPadMode {
                legendChip("K / L", "bank")
                legendChip("O / P", "louder / quieter")
            } else {
                legendChip("Z / X", isChordMode ? "higher / lower" : "octave")
                legendChip("C / V", "louder / quieter")
            }
            // m34-l. The chip LIGHTS with the pedal — a second, in-place answer
            // to "is it down?" right where the user's eye is when they are
            // reading which key does what.
            legendChip("⇥", "hold the sound", isOn: isSustainDown)
            if isChordMode {
                // Rule 6: say what the row above actually means, in the words a
                // beginner would use, rather than assuming the lights explain
                // themselves.
                //
                // ⚠️ **"IN ORDER" WAS RETIRED AT m34-i BECAUSE IT STOPPED BEING
                // TRUE OF A STILL PICTURE.** The order used to be printed on the
                // keys as numbers; it is now a border that MOVES, so the line has
                // to name the moving thing. And it changes with the preset
                // picker, because "follow the outline" is nonsense when there is
                // no outline to follow.
                Text(controller.progression == nil
                     ? "Every key plays a chord. Pick a preset — or press NEW LIGHTS — to be shown what to play."
                     : "Follow the bright outline — that's your next chord. "
                       + "The bars under the keys after it show what's coming, widest first. Every key still plays.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
            if isPadMode {
                // Rule 6: say what the squares mean in the words a beginner
                // would use — including the one fact a still picture cannot
                // convey, that where you click changes how hard it hits.
                Text("The Z X C V / A S D F / Q W E R / 1 2 3 4 block plays the "
                     + "sixteen pads, laid out like the grid. Click high on a pad "
                     + "for a harder hit.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
            Spacer(minLength: 0)
            Text("Space still plays and stops. ⌘ shortcuts still work.")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textFaint)
        }
    }

    // MARK: - Chord mode chrome

    private func modeChip(_ title: String, isOn: Bool, action: @escaping () -> Void)
        -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(isOn ? DAWTheme.noteInkOnDark : DAWTheme.textDim)
                .frame(height: 20)
                .padding(.horizontal, 9)
                .background(isOn ? DAWTheme.playback.opacity(0.85) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(title == "CHORDS"
              ? "One key plays a whole chord in the key you pick."
              : "One key plays one note.")
    }

    /// PICK A KEY + PRESET — the two pickers the user's mock-up puts on its first
    /// line, in the order it puts them.
    private var chordPickers: some View {
        HStack(spacing: 14) {
            pickerLabel("PICK A KEY")
            Menu {
                ForEach(KeyMode.allCases, id: \.self) { mode in
                    Section(mode.displayName.uppercased()) {
                        ForEach(0..<12, id: \.self) { pitchClass in
                            Button(Self.keyName(pitchClass, mode)) {
                                onSetKey(pitchClass, mode)
                            }
                        }
                    }
                }
            } label: {
                Text(Self.keyName(controller.chordKey, controller.chordKeyMode))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.playback)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which key the chords belong to. Everything stays in this key.")

            pickerLabel("PLAYED LIKE")
            Menu {
                ForEach(VoicingPresetKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) { onSetVoicingPreset(kind) }
                }
            } label: {
                Text(controller.voicingPreset.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.playback)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(controller.voicingPreset.summary)

            Text(controller.voicingPreset.summary)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textFaint)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func pickerLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(DAWTheme.textDim)
    }

    private static func keyName(_ pitchClass: Int, _ mode: KeyMode) -> String {
        // The repo's SOLE pitch-class-name array, read rather than copied.
        let names = KeyEstimate.pitchClassesSharp
        let index = ((pitchClass % names.count) + names.count) % names.count
        return names[index] + " " + mode.displayName
    }

    /// ⭐ **THE PROGRESSION ROW — A HIGHLIGHT OVERLAY, NEVER A MODE.** Selecting
    /// one lights four or five of the SAME keys the scale already plays and
    /// **starts the next-chord border on the progression's first chord**; the rest
    /// stay dim and fully playable. That is the user's own choice, verbatim:
    /// *"Follow the lights, or ignore them. Same keys either way."*
    ///
    /// ⚠️ **RE-CLICKING THE SELECTED PRESET RESTARTS THE SEQUENCE** — see
    /// `MusicalTypingController.setProgression` for why that is deliberate.
    private var progressionRow: some View {
        HStack(spacing: 6) {
            pickerLabel("PRESET")
            progressionChip(nil, title: "None",
                            help: "No lights — every chord in the key, equally.")
            ForEach(ChordProgressionLibrary.all) { preset in
                progressionChip(preset, title: preset.name,
                                help: preset.blurb + "  " + preset.numeralLine())
            }
            Spacer(minLength: 0)
        }
    }

    private func progressionChip(_ preset: ChordProgressionPreset?,
                                 title: String, help: String) -> some View {
        let isOn = controller.progression?.id == preset?.id
        return Button { onSetProgression(preset) } label: {
            Text(title)
                .font(.system(size: 10, weight: isOn ? .bold : .regular))
                .foregroundStyle(isOn ? DAWTheme.noteInkOnDark : DAWTheme.textSecondary)
                .frame(height: 20)
                .padding(.horizontal, 8)
                .background(isOn ? DAWTheme.playback.opacity(0.85) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(isOn ? Color.clear : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// ⭐⭐⭐ **PLAYBOX (m34-g) — THE AI SHOWS YOU WHAT TO PLAY, YOU PLAY IT, AND
    /// IT IS YOURS.** The user's own idea: *"it would be nice to have a playbox
    /// mode where AI would pre-generate next series of lights to play and
    /// record."*
    ///
    /// ⛔⛔ **THE BUTTON LIGHTS KEYS. IT PLAYS NOTHING.** This row generates an
    /// INVITATION; the performance is the user's, on the keys, through the same
    /// live capture path as any other take. That inversion is the whole point,
    /// and for a non-musician with no MIDI hardware it is the difference between
    /// owning the music and receiving it.
    ///
    /// ⭐ **THE MODE SWITCH IS HERE, VISIBLE, BECAUSE THEY ASKED TO CHOOSE** —
    /// *"provide all three options to select from on advancing mode"* — and the
    /// three are three different USES: wait-for-you is learning the part,
    /// on-the-beat is performing it, lights-run-ahead is writing with it.
    private var playboxRow: some View {
        HStack(spacing: 6) {
            pickerLabel("PLAYBOX")
            Button(action: onGeneratePlaybox) {
                HStack(spacing: 5) {
                    Image(systemName: isGeneratingPlaybox
                          ? "circle.dotted" : "sparkles")
                        .font(.system(size: 9, weight: .bold))
                    Text(isGeneratingPlaybox ? "THINKING…" : "NEW LIGHTS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                }
                // Violet ALWAYS means AI-generated (docs/DESIGN-LANGUAGE.md), and
                // this button is the door to the AI path, so it is violet even
                // before anything has been generated.
                .foregroundStyle(isGeneratingPlaybox ? DAWTheme.textDim : DAWTheme.ai)
                .frame(height: 20)
                .padding(.horizontal, 9)
                .background(DAWTheme.ai.opacity(isGeneratingPlaybox ? 0.06 : 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(DAWTheme.ai.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isGeneratingPlaybox)
            .help("Ask for a fresh set of chords to play, in your key and tempo. "
                  + "It lights the keys — you play them.")

            pickerLabel("LIGHTS MOVE")
            ForEach(ChordSequenceAdvanceMode.allCases, id: \.self) { mode in
                advanceModeChip(mode)
            }

            // ⛔⛔ **WHO WROTE THESE LIGHTS, SAID OUT LOUD.** "The AI wrote this"
            // and "we picked a stock progression" are different claims and only
            // one of them is true at a time. Violet only when it is genuinely
            // the first; the neutral hierarchy otherwise.
            if let provenance = controller.playboxProvenance {
                Text(provenance.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(provenance.isAI ? DAWTheme.ai : DAWTheme.textDim)
                    .lineLimit(1)
                    .help(provenance.reason ?? provenance.summary)
            }

            Spacer(minLength: 0)
        }
    }

    private func advanceModeChip(_ mode: ChordSequenceAdvanceMode) -> some View {
        let isOn = controller.advanceMode == mode
        return Button { onSetAdvanceMode(mode) } label: {
            Text(mode.displayName)
                .font(.system(size: 9, weight: isOn ? .bold : .regular,
                              design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(isOn ? DAWTheme.noteInkOnDark : DAWTheme.textSecondary)
                .frame(height: 20)
                .padding(.horizontal, 8)
                .background(isOn ? DAWTheme.playback.opacity(0.85) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(isOn ? Color.clear : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(mode.summary)
    }

    /// `isOn` lights the chip (m34-l) — additive: it defaults false, so the four
    /// chips that had no state before draw byte-identically.
    private func legendChip(_ keys: String, _ meaning: String,
                            isOn: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? DAWTheme.signal : DAWTheme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isOn ? DAWTheme.signal.opacity(0.16) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(meaning)
                .font(.system(size: 10))
                .foregroundStyle(isOn ? DAWTheme.signal.opacity(0.9) : DAWTheme.textDim)
        }
    }
}
