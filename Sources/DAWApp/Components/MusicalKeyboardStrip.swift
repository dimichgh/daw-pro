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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            keyboard
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

            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(canSound ? DAWTheme.textSecondary : DAWTheme.record)
                .lineLimit(1)

            Spacer(minLength: 12)

            // SF Mono for every numeric readout (docs/DESIGN-LANGUAGE.md
            // "Foundations"). OCTAVE reads as the note the `A` key sounds rather
            // than as a bare number — Rule 6: a beginner should not have to know
            // what "octave 4" means to find the note they just played.
            DigitalReadout(label: "Octave", value: octaveValue,
                           color: DAWTheme.playback, valueSize: 15)
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
            legendChip("Z / X", "octave")
            legendChip("C / V", "louder / quieter")
            Spacer(minLength: 0)
            Text("Space still plays and stops. ⌘ shortcuts still work.")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textFaint)
        }
    }

    private func legendChip(_ keys: String, _ meaning: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DAWTheme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(meaning)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
        }
    }
}
