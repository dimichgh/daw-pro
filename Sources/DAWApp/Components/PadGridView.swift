import SwiftUI
import DAWCore
import DAWAppKit

/// **THE PAD GRID (m39-pads)** — the strip's THIRD face, and the first surface
/// in this app from which a human can play a chop.
///
/// ## Why it lives inside the Musical Typing strip
///
/// The strip already resolves the hard half of a performance surface: which
/// track is the target, whether it can sound, whether a take is capturing, the
/// sustain pedal, the velocity, release-on-record-edge and release-on-track-
/// change. A pad grid mounted anywhere else would need every one of those again,
/// and the second copy would drift. The strip's own comment already calls this
/// out — *"ONE SURFACE, TWO FACES … the piano is not relabelled, it is
/// REPLACED"* — and a pad grid is the third face by exactly that argument: in
/// pads mode a key no longer names a pitch on a keyboard, it names a SLICE, so
/// drawing a piano and writing slice numbers on it would be a picture that lies
/// about what a click does.
///
/// ## Drawing
///
/// ⚠️ **NOT a `Canvas`, and that is a considered exception to the house pattern
/// rather than an oversight.** `Canvas` + `TimelineView` is the recipe for
/// surfaces that redraw CONTINUOUSLY — meters, scopes, waveforms — where the
/// cost of a view per element is paid sixty times a second. A pad grid redraws
/// on note-on, note-off, bank change and chop: discrete events, tens per minute
/// at a hard performance. Sixteen light views buy real hit-testing, real
/// `.help` tooltips, real accessibility labels, and the ONE `glow()` recipe from
/// `Theme.swift` rather than a second copy of it written as
/// `GraphicsContext.addFilter(.shadow(...))`. There is nothing per-frame here to
/// allocate, because there is no frame.
///
/// Every input is a plain value (`[PadState]`, two colours, a closure), so a
/// preview, a test and the running app draw the identical surface.
struct PadGridView: View {
    /// The sixteen pads of the current bank, already resolved.
    var pads: [PadState]
    /// 0-based bank, and how many there are.
    var bank: Int
    var bankCount: Int
    /// Frames spanned by the loaded pads — the position bar's denominator. nil
    /// hides the bars (see `PadState.startFrame`: seconds would need file I/O).
    var frameSpan: ClosedRange<Int>?
    /// Can the target actually sound? Drives the whole surface's ink, so the
    /// grid never looks live over a track that cannot make a noise.
    var canSound: Bool
    /// What a pad does when you let go, or nil when the target is not a
    /// built-in sampler and there is nothing to set.
    var triggerMode: PadTriggerMode?
    /// The store's refusal from the last attempt to change it.
    var triggerModeError: String?
    /// Why the row is dead, when it is. ⚠️ It becomes the row's tooltip: the
    /// CHIPS' own help describes pads this track does not have, and a disabled
    /// control explaining a capability that is not there is worse than silence.
    var triggerModeUnavailableReason: String?
    /// Struck: pad index + where in the pad, 0 = top edge.
    var onPadDown: (Int, Double) -> Void
    var onPadUp: () -> Void
    var onSetBank: (Int) -> Void
    var onSetTriggerMode: (PadTriggerMode) -> Void
    /// SIXTEEN LEVELS: is a spread up, is the grid waiting for a pad, what the
    /// header should say, why the button is dead, and the last refusal.
    var isLevels: Bool = false
    var levelsArming: Bool = false
    var levelsStatus: String?
    var levelsUnavailableReason: String?
    var levelsError: String?
    var onToggleLevels: () -> Void = {}

    /// Pad edge, and the gap between pads. Generous: this is a surface fingers
    /// aim at, and the design language asks for generous spacing before it asks
    /// for density.
    private static let padSize: CGFloat = 62
    private static let padGap: CGFloat = 7

    /// Which pad the pointer is holding, so the press reads as a press. nil when
    /// nothing is down.
    ///
    /// ⚠️ **PRESSED IS NOT PLAYING.** This state draws the finger; `PadState.isPlaying`
    /// draws the SOUND, and it is read back from the controller's `soundingPitches`.
    /// They differ exactly when it matters — a pad struck on a track that cannot
    /// sound depresses and stays dark — and collapsing them into one would make
    /// the grid claim audio that never happened, which is this tree's
    /// characteristic failure in pixel form.
    @State private var pressedPad: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            bankRow
            grid
            // ⚠️ ITS OWN LINE, NOT TUCKED INTO `bankRow`. Four bank chips plus
            // "K / L switches bank" plus two word-chips would not fit the
            // grid's 269 pt at four banks, and the casualty would be the hint
            // text — a layout nobody has looked at is exactly what this
            // project's own law says not to ship.
            triggerModeRow
            if let levelsStatus {
                Text(levelsStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(levelsArming ? DAWTheme.record : DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let levelsError {
                Text(levelsError)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let triggerModeError {
                // ⚠️ SHOWN, not swallowed. The sampler apply is wholesale and
                // can refuse; a chip that lit while the write bounced would be
                // a switch claiming a state the engine is not in.
                Text(triggerModeError)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The grid

    private var grid: some View {
        VStack(spacing: Self.padGap) {
            ForEach(0..<PadGridGeometry.rows, id: \.self) { row in
                HStack(spacing: Self.padGap) {
                    ForEach(0..<PadGridGeometry.columns, id: \.self) { column in
                        if let index = PadGridGeometry.padIndex(displayRow: row, column: column),
                           index < pads.count {
                            pad(pads[index])
                        }
                    }
                }
            }
        }
        // One release for the whole grid: a drag that starts on a pad and ends
        // anywhere must still let go, or a pointer slid off the surface strands
        // a ringing note.
        .onDisappear { release() }
    }

    private func pad(_ state: PadState) -> some View {
        let tint = padTint(state)
        let isLit = state.isPlaying && canSound
        return RoundedRectangle(cornerRadius: 9)
            .fill(padFill(state, tint: tint, isLit: isLit))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(padStroke(state, tint: tint, isLit: isLit),
                            lineWidth: isLit ? 1.5 : 1)
            }
            .overlay { padLabels(state, isLit: isLit) }
            .overlay(alignment: .bottom) { positionBar(state, tint: tint, isLit: isLit) }
            // ⭐ THE GLOW RECIPE, and ONLY on a sounding pad. "Never glow static
            // chrome" (Rule 3) — an idle pad that glowed would make the whole
            // grid one flat wash and take the meaning out of the one that fires.
            .glow(tint, radius: isLit ? 9 : 0, intensity: isLit ? 0.65 : 0)
            .scaleEffect(pressedPad == state.id ? 0.965 : 1)
            .animation(.easeOut(duration: 0.12), value: isLit)
            .animation(.easeOut(duration: 0.08), value: pressedPad == state.id)
            .frame(width: Self.padSize, height: Self.padSize)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .gesture(padGesture(state))
            .help(tooltip(state))
            .accessibilityLabel(accessibilityText(state))
            .accessibilityAddTraits(.isButton)
    }

    /// Cyan for a normal slice; **VIOLET whenever the material is AI-touched.**
    /// One law, no exceptions — the same rule the piano roll's note pills and the
    /// step sequencer's cells obey, so three surfaces over one sound cannot
    /// disagree about where it came from.
    private func padTint(_ state: PadState) -> Color {
        state.isAITouched ? DAWTheme.ai : DAWTheme.playback
    }

    private func padFill(_ state: PadState, tint: Color, isLit: Bool) -> Color {
        guard state.pitch != nil else {
            // Past MIDI 127 — there is no note here to play. Reads as a hole in
            // the surface, not as an empty pad you could load.
            return DAWTheme.background.opacity(0.65)
        }
        if isLit { return tint }
        // ⭐ LOADED vs EMPTY IS A FILL DIFFERENCE, NOT A BORDER DIFFERENCE. A
        // grid where you cannot tell the two apart at a glance is not usable,
        // and a 1 px border change is not a glance-level difference — the
        // loaded pad is a raised panel, the empty one is a recess.
        return state.isLoaded ? DAWTheme.panelRaised : DAWTheme.background.opacity(0.9)
    }

    private func padStroke(_ state: PadState, tint: Color, isLit: Bool) -> Color {
        if isLit { return tint }
        guard state.pitch != nil else { return DAWTheme.hairline }
        // A loaded pad carries a dim trace of its own accent, so the loaded
        // block reads as one region even before anything is struck.
        return state.isLoaded ? tint.opacity(canSound ? 0.34 : 0.16) : DAWTheme.hairline
    }

    /// The three labels: the key that drums it, the slice it holds, the note it
    /// fires.
    @ViewBuilder
    private func padLabels(_ state: PadState, isLit: Bool) -> some View {
        let ink = labelInk(state, isLit: isLit)
        VStack(spacing: 2) {
            // The letter key, big — this is a finger-drumming surface and the
            // key is what the hand is looking for.
            Text(state.keyLabel ?? "·")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(ink.primary)
            // SF Mono for every numeric readout (Foundations). "12" is a slice
            // ordinal, not decoration.
            // ⭐ IN A SPREAD THIS IS THE INTERVAL, NOT THE SLICE NUMBER. Every
            // pad is the same zone there, so sixteen squares would all read
            // "7" while each played a different pitch — true of the zone,
            // false of the sound. `PadState.levelsSemitones` decides.
            Text(state.levelsSemitones.map(SixteenLevels.offsetLabel(semitones:))
                 ?? state.sliceOrdinal.map { "\($0)" } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(state.levelsSemitones == 0 ? ink.primary : ink.secondary)
            Text(state.noteName)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(ink.tertiary)
        }
        .padding(.bottom, 4)
        .allowsHitTesting(false)
    }

    /// ⭐ **THE DUAL-INK LAW.** A lit pad is a saturated cyan or violet surface,
    /// and the dark hierarchy is unreadable on it. Which polarity the ink takes
    /// is DERIVED from the pad's own composited luminance through `NotePillInk`
    /// — the app's ONE home for that question — rather than picked, so it cannot
    /// go stale if an accent ever moves.
    private func labelInk(_ state: PadState, isLit: Bool)
        -> (primary: Color, secondary: Color, tertiary: Color) {
        guard state.pitch != nil else {
            return (DAWTheme.textFaint, DAWTheme.textFaint, DAWTheme.textFaint)
        }
        if isLit {
            let hex = state.isAITouched ? DAWTheme.aiHex : DAWTheme.playbackHex
            let dark = NotePillInk.prefersDarkInk(
                tint: SRGBColor(hex: hex), alpha: 1,
                backdrop: SRGBColor(hex: DAWTheme.panelHex))
            let ink = dark ? DAWTheme.noteInkOnLight : DAWTheme.noteInkOnDark
            return (ink, ink.opacity(0.78), ink.opacity(0.6))
        }
        if !state.isLoaded {
            // An empty pad is a placeholder, and `textFaint` is the placeholder
            // floor. Deliberately NOT dimmed further with `.opacity()` — the
            // hierarchy has a floor precisely so ad-hoc dimming stops here.
            return (DAWTheme.textFaint, DAWTheme.textFaint, DAWTheme.textFaint)
        }
        return (DAWTheme.textPrimary, DAWTheme.textSecondary, DAWTheme.textDim)
    }

    /// Where this slice sits in the record, as a fraction of the loaded span.
    ///
    /// ⚠️ **A BAR, NOT A TIME.** `SamplerZone` stores FRAMES; seconds need the
    /// file's sample rate and reading it means main-actor file I/O (the m26-i
    /// ruling). A fraction needs no rate at all, and a picture of "this one is
    /// near the end" is what a performer actually wants from a pad anyway.
    @ViewBuilder
    private func positionBar(_ state: PadState, tint: Color, isLit: Bool) -> some View {
        if let span = frameSpan, let frame = state.startFrame, span.upperBound > span.lowerBound {
            let fraction = Double(frame - span.lowerBound)
                / Double(span.upperBound - span.lowerBound)
            GeometryReader { geo in
                Capsule()
                    .fill(isLit ? DAWTheme.noteInkOnDark.opacity(0.5) : tint.opacity(0.42))
                    .frame(width: 3, height: 2)
                    .offset(x: (geo.size.width - 3) * min(1, max(0, fraction)))
            }
            .frame(height: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 5)
            .allowsHitTesting(false)
        }
    }

    // MARK: - The gesture

    /// ⚠️ `minimumDistance: 0` so a plain CLICK is a complete press — the same
    /// shape `DeferredKnob` documents. `onChanged` fires repeatedly during a
    /// drag, so the strike is gated on the pad not already being down: without
    /// that guard a held finger would re-strike the pad on every mouse-moved
    /// event and machine-gun the slice.
    private func padGesture(_ state: PadState) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pressedPad != state.id else { return }
                pressedPad = state.id
                let y = Self.padSize > 0 ? value.location.y / Self.padSize : 0.5
                onPadDown(state.id, y)
            }
            .onEnded { _ in release() }
    }

    private func release() {
        guard pressedPad != nil else { return }
        pressedPad = nil
        onPadUp()
    }

    // MARK: - Banks

    /// ⚠️ **ALWAYS DRAWN, EVEN AT ONE BANK**, and that is deliberate: a row that
    /// appeared only once a chop grew past 16 slices would teach the user that
    /// 16 is all there is. With one bank the single chip reads as a label.
    private var bankRow: some View {
        HStack(spacing: 8) {
            Text("BANK")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            HStack(spacing: 0) {
                ForEach(0..<max(1, bankCount), id: \.self) { index in
                    bankChip(index)
                }
            }
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))

            Text("K / L switches bank")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textFaint)
            Spacer(minLength: 0)
        }
    }

    // MARK: - What a pad does when you let go

    /// ⭐ **THE ROW ASKS THE QUESTION AND THE CHIPS FINISH THE SENTENCE** —
    /// "LET GO: STOPS" / "LET GO: PLAYS ON". Naming the two states ONE SHOT and
    /// NOTE ON, as hardware does, would be correct and would teach a newcomer
    /// nothing; the words here are what they will hear.
    ///
    /// ⚠️ **ALWAYS DRAWN, DIM WHEN DEAD** — the `bankRow` rule. A control that
    /// vanished over a non-sampler track would leave the surface silently
    /// missing the one setting that explains why a click made almost no sound.
    @ViewBuilder
    private var triggerModeRow: some View {
        HStack(spacing: 8) {
            Text("LET GO")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(triggerMode == nil ? DAWTheme.textFaint : DAWTheme.textDim)
            HStack(spacing: 0) {
                ForEach(PadTriggerMode.allCases, id: \.self) { value in
                    triggerModeChip(value)
                }
            }
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
            .opacity(triggerMode == nil ? 0.45 : 1)
            if triggerMode != nil {
                Text("A tap is a very short hold.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textFaint)
            }
            Spacer(minLength: 8)
            levelsButton
        }
        // ⚠️ The ROW answers for the dead case; see `triggerModeUnavailableReason`.
        .help(triggerModeUnavailableReason ?? "")
    }

    private func triggerModeChip(_ value: PadTriggerMode) -> some View {
        let isOn = triggerMode == value
        return Button { onSetTriggerMode(value) } label: {
            Text(value.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? DAWTheme.background : DAWTheme.textDim)
                .frame(height: 18)
                .padding(.horizontal, 7)
                .background(isOn ? DAWTheme.playback : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(triggerMode == nil)
        .help(value.help)
    }

    /// ⭐ **ONE BUTTON, THREE STATES, AND THE LABEL SAYS WHICH.** Off it offers
    /// LEVELS; armed it says PICK A PAD in amber, because the grid is waiting
    /// for something and a control that looked identical while the meaning of a
    /// click had changed would be the affordance-lies shape; live it says EXIT
    /// LEVELS, so the way out is the same button that got you in.
    private var levelsButton: some View {
        let label = isLevels ? "EXIT LEVELS" : (levelsArming ? "PICK A PAD" : "LEVELS")
        let lit = isLevels || levelsArming
        let tint = levelsArming ? DAWTheme.record : DAWTheme.playback
        return Button(action: onToggleLevels) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(lit ? DAWTheme.background : DAWTheme.textDim)
                .frame(height: 18)
                .padding(.horizontal, 8)
                .background(lit ? tint : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isLevels && levelsUnavailableReason != nil)
        .opacity(!isLevels && levelsUnavailableReason != nil ? 0.45 : 1)
        // ⚠️ The REASON, when there is one — a dimmed button that explains
        // nothing teaches nothing.
        .help(levelsUnavailableReason
              ?? "Spread one slice across all sixteen pads, a semitone apart, "
              + "so you can play it. Your chop is untouched and comes back when you exit.")
    }

    private func bankChip(_ index: Int) -> some View {
        let isOn = index == bank
        return Button { onSetBank(index) } label: {
            // Letters, not numbers: an MPC's banks are A/B/C/D, and a "2" beside
            // a grid full of slice numbers is one numeral too many to parse at
            // a glance.
            Text(String(UnicodeScalar(UInt8(65 + min(25, index)))))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? DAWTheme.background : DAWTheme.textDim)
                .frame(width: 22, height: 18)
                .background(isOn ? DAWTheme.playback : Color.clear)
        }
        .buttonStyle(.plain)
        .help("Pads \(index * PadGridGeometry.padsPerBank + 1)–"
              + "\((index + 1) * PadGridGeometry.padsPerBank) of this kit.")
    }

    // MARK: - Words

    private func tooltip(_ state: PadState) -> String {
        guard state.pitch != nil else {
            return "This bank runs past the top of MIDI — there is no note here to play."
        }
        let key = state.keyLabel.map { "Key “\($0)”. " } ?? ""
        guard state.isLoaded, let ordinal = state.sliceOrdinal else {
            return key + "Empty — note \(state.noteName). Chop a clip onto the pads to fill it."
        }
        return key + "Slice \(ordinal), note \(state.noteName)."
            + (state.isAITouched ? " AI-generated material." : "")
    }

    private func accessibilityText(_ state: PadState) -> String {
        guard state.pitch != nil else { return "Pad out of MIDI range" }
        guard state.isLoaded, let ordinal = state.sliceOrdinal else {
            return "Empty pad, note \(state.noteName)"
        }
        return "Pad playing slice \(ordinal), note \(state.noteName)"
    }
}
