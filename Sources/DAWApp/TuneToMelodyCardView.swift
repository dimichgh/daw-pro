import DAWAppKit
import DAWCore
import SwiftUI

// Tune to Melody, M3 (W7-TTM3; design `2026-09-24-unpitched-notes-presets-midi-targets.md`
// §3.4) — THE CARD AND ITS MENU ITEM, DRAWN. Thin on purpose: every decision (what the menu
// offers, what the card lists, what Apply sends, every word) is DAWAppKit's
// `TuneToMelodyCard` / `TuneToMelodyCopy`, tested headless. These views take plain values and
// closures, so a preview and the app draw the same thing.
//
// APP CHROME, not AI content: NO violet (tuning to a melody is the app's own DSP, not a
// generation). Cyan marks the ACTIVE pick (the palette's active-state ink); green marks the one
// success line; amber marks "take care" (the far-move note) and a refusal. Nothing at rest glows.

/// The clip menu's **Tune Vocal ▸ Tune to Melody…** item.
///
/// ⚡ **ITS OWN VIEW, SO ITS QUESTION IS ASKED WHEN THE MENU IS BUILT.** The clip block is
/// rebuilt as the playhead moves; `availability` is a closure the block hands down, and this
/// body is where it is called. `TuneToMelodyMenu.availability` is cheap anyway (a beat-span
/// prefilter before the store's own per-note function).
///
/// ⭐ **DISABLED, AND SAYS WHY WHERE A NOVICE CAN READ IT.** A tooltip on a disabled menu item
/// needs a hover a beginner will not think to make, so the reason is ALSO drawn as a greyed line
/// right under the item ("Add a MIDI melody under this vocal first.").
struct TuneToMelodyMenuItem: View {
    var availability: () -> TuneToMelodyMenu.Availability
    var action: () -> Void

    var body: some View {
        let state = availability()
        Button(TuneToMelodyCopy.menuTitle, action: action)
            .disabled(!state.isEnabled)
            .help(state.help)
        if !state.isEnabled {
            Text(state.help)
        }
    }
}

/// **TUNE TO MELODY** — the card the menu item opens: a melody picker, the preset chips, the
/// Match octave switch, Apply, and the one result line.
///
/// The `PresetReplaceConfirmCard` / `ChopToPadsPanel` shape: a centred dark-glass card over a
/// dimmed scrim, INSIDE the window (an `NSPanel` or a sheet would be a stock grey surface and
/// invisible to `debug.captureUI`).
///
/// ⭐ **NO KEY ANSWERS THIS CARD: Close is the ✕, Apply is the button.** Return is bound to
/// nothing, so a stray keypress cannot retune anybody's vocal. Escape is bound to nothing
/// either, deliberately, for now: every `.cancelAction` in the app must be named where
/// `EscapeKeyMonitorSiteTests.everyKeyEquivalentEscapeIsNamed` counts them (the key monitor
/// runs before a key equivalent), and with the replace card up over this one, two of them
/// would compete for one Escape. The card IS a listed modal (`isModalPresented`), so Escape
/// reaches nothing behind it. The `ChopToPadsPanel` precedent.
struct TuneToMelodyCardView: View {
    let card: TuneToMelodyCard
    var onSelect: (String) -> Void
    var onPreset: (PitchCorrectionPreset) -> Void
    var onMatchOctave: (Bool) -> Void
    var onApply: () -> Void
    var onClose: () -> Void

    private typealias L = TuneToMelodyCardLayout
    private typealias W = TuneToMelodyCopy

    var body: some View {
        ZStack {
            // Scrim. No tap-to-dismiss: a click that misses the card is not an answer.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
            panel
                .frame(width: L.cardWidth)
                .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
        }
        .transition(.opacity)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: L.sectionSpacing) {
            VStack(alignment: .leading, spacing: L.innerSpacing) {
                header
                sourceLine
                Text(W.intro)
                    .font(.system(size: L.bodySize))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            melodySection
            soundSection
            octaveSection
            resultSection
            footer
        }
        .padding(L.padding)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(W.title)
                .font(.system(size: L.titleSize, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(card.canClose ? DAWTheme.textDim : DAWTheme.textFaint)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!card.canClose)
            .help(W.closeHelp)
        }
        .frame(height: L.headerHeight)
    }

    /// What is about to be tuned, named, so the person can see it is the clip they meant.
    private var sourceLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
            Text(W.sourceLine(vocalName: card.vocalName, trackName: card.vocalTrackName))
                .font(.system(size: L.sourceSize))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - The melody picker

    @ViewBuilder
    private var melodySection: some View {
        VStack(alignment: .leading, spacing: L.innerSpacing) {
            fieldLabel(W.melodyLabel)
            if card.choices.isEmpty {
                PanelRefusalLine(message: W.noMelodyUnderVocal)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: L.rowSpacing) {
                        ForEach(card.choices) { choice in
                            choiceRow(choice)
                        }
                    }
                }
                .scrollIndicators(card.choices.count > L.maxVisibleRows ? .automatic : .hidden)
                .frame(height: L.pickerHeight(rows: card.choices.count))
            }
        }
    }

    private func choiceRow(_ choice: TuneToMelodyChoice) -> some View {
        let isOn = choice.id == card.selected?.id
        return Button { onSelect(choice.id) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn ? DAWTheme.playback : Color.clear)
                    .overlay(Circle().stroke(isOn ? DAWTheme.playback : DAWTheme.textFaint,
                                             lineWidth: 1))
                    .frame(width: 9, height: 9)
                Text(W.choiceName(choice))
                    .font(.system(size: L.rowNameSize, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? DAWTheme.textPrimary : DAWTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: L.rowMinNameWidth, alignment: .leading)
                Spacer(minLength: 8)
                Text(W.choiceDetail(choice))
                    .font(.system(size: L.rowDetailSize))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
                    .fixedSize()
            }
            // A clip row sits under its track.
            .padding(.leading, choice.isClip ? L.rowHorizontalPadding + 14 : L.rowHorizontalPadding)
            .padding(.trailing, L.rowHorizontalPadding)
            .frame(height: L.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? DAWTheme.panelRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isOn ? DAWTheme.playback.opacity(0.6) : DAWTheme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!card.canEdit)
        .help(W.choiceDetail(choice))
    }

    // MARK: - The preset chips

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: L.innerSpacing) {
            fieldLabel(W.soundLabel)
            HStack(spacing: 0) {
                ForEach(TuneToMelodyCard.presets) { preset in
                    let isOn = card.preset == preset
                    Button { onPreset(preset) } label: {
                        Text(preset.displayName)
                            .font(.system(size: L.chipLabelSize, weight: .semibold))
                            .foregroundStyle(isOn ? DAWTheme.background : DAWTheme.textSecondary)
                            .lineLimit(1)
                            .frame(height: L.chipHeight)
                            .frame(maxWidth: .infinity)
                            .background(isOn ? DAWTheme.playback : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .disabled(!card.canEdit)
                    .help(W.presetLine(preset))
                }
            }
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            // Every chip's line is laid out, only the picked one shown: the lines wrap to
            // different heights, and the card must not jump when a chip is clicked.
            ZStack(alignment: .topLeading) {
                ForEach(TuneToMelodyCard.presets) { preset in
                    Text(W.presetLine(preset))
                        .font(.system(size: L.captionSize))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(preset == card.preset ? 1 : 0)
                        .accessibilityHidden(preset != card.preset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Match octave

    private var octaveSection: some View {
        VStack(alignment: .leading, spacing: L.innerSpacing) {
            Button { onMatchOctave(!card.matchOctave) } label: {
                HStack(spacing: L.checkboxSpacing) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(card.matchOctave ? DAWTheme.playback : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(card.matchOctave ? DAWTheme.playback : DAWTheme.textFaint,
                                    lineWidth: 1))
                        .overlay {
                            if card.matchOctave {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundStyle(DAWTheme.background)
                            }
                        }
                        .frame(width: L.checkboxSize, height: L.checkboxSize)
                    Text(W.octaveLabel)
                        .font(.system(size: L.bodySize))
                        .foregroundStyle(DAWTheme.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!card.canEdit)
            Text(card.matchOctave ? W.octaveOnLine : W.octaveOffLine)
                .font(.system(size: L.captionSize))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, L.checkboxSize + L.checkboxSpacing)
        }
    }

    // MARK: - The result

    @ViewBuilder
    private var resultSection: some View {
        switch card.phase {
        case .finished(let outcome):
            VStack(alignment: .leading, spacing: L.innerSpacing) {
                resultLine(W.summary(outcome),
                           symbol: outcome.foundSinging ? "checkmark.circle.fill"
                                                        : "exclamationmark.triangle.fill",
                           ink: outcome.foundSinging ? DAWTheme.signal : DAWTheme.record,
                           textInk: DAWTheme.textPrimary, size: L.bodySize)
                if let note = W.farMoveNote(outcome) {
                    resultLine(note, symbol: "exclamationmark.triangle.fill", ink: DAWTheme.record,
                               textInk: DAWTheme.textSecondary, size: L.captionSize)
                }
            }
        case .refused(let message):
            PanelRefusalLine(message: message)
        case .choosing, .waitingForAnswer, .tuning:
            EmptyView()
        }
    }

    private func resultLine(_ text: String, symbol: String, ink: Color, textInk: Color,
                            size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(ink)
                .frame(width: L.resultIconColumn, alignment: .leading)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(textInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(W.undoNote)
                .font(.system(size: L.captionSize))
                .foregroundStyle(DAWTheme.textFaint)
            Spacer(minLength: 0)
            Button(action: onApply) {
                HStack(spacing: 6) {
                    if card.phase == .tuning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                    Text(card.phase == .tuning ? W.tuningLabel : W.applyLabel)
                        .font(.system(size: L.buttonLabelSize, weight: .bold, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(card.canApply ? DAWTheme.background : DAWTheme.textFaint)
                .frame(height: L.footerHeight)
                .padding(.horizontal, 18)
                .background(card.canApply ? DAWTheme.playback : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(card.canApply ? Color.clear : DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!card.canApply)
            .help(card.choices.isEmpty ? W.noMelodyUnderVocal : W.applyHelp)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: L.fieldLabelSize, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(DAWTheme.textDim)
    }
}
