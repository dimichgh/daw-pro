import SwiftUI
import AIServices
import DAWCore
import DAWAppKit

// p2-sing-x8: the Sing sheet's Expression and Harmony cards (design 2026-10-06 §5.1, §4.1), thin over
// `SingExpressionModel` and `SingSheetModel`. A discrete setting is a CHIP THAT NAMES IT (the m39-ag law): the five
// vibrato choices, the wordless sounds and modes. Lit = cyan (active), the house's semantic accent.

/// A small chip that names a setting; lit when it is the current one.
struct SingChip: View {
    var title: String
    var isLit: Bool
    var isEnabled: Bool = true
    var help: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: isLit ? .semibold : .medium))
                .foregroundStyle(isLit ? DAWTheme.playback : DAWTheme.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(isLit ? DAWTheme.playback.opacity(0.16) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(isLit ? DAWTheme.playback.opacity(0.7) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help ?? title)
        .fixedSize()
    }
}

/// The Expression card (§5.1): closed by default ("Style: as sung"); open, vibrato as five chips, Air as a slider
/// from None to Lots (written on release), and "Follow note loudness". While it is open, clicking notes in the strip
/// picks them, and the card applies to just those.
struct SingExpressionCardView: View {
    var model: SingExpressionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.toggleExpanded() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                        .frame(width: 10)
                    Text(SingCopy.expressionSection)
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(DAWTheme.textDim)
                    Text(model.summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let line = model.selectionLine {
                        Text(line)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DAWTheme.playback)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.isExpanded { controls }
            if let refusal = model.refusal { PanelRefusalLine(message: refusal) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                label(SingCopy.vibratoLabel)
                ForEach(SingStyle.Vibrato.allCases, id: \.self) { vibrato in
                    SingChip(title: SingCopy.vibratoName(vibrato), isLit: model.vibrato == vibrato,
                             help: SingCopy.vibratoHelp) { model.setVibrato(vibrato) }
                }
            }
            .help(SingCopy.vibratoHelp)
            HStack(spacing: 6) {
                label(SingCopy.airLabel)
                Text(SingCopy.airNone)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DAWTheme.textDim)
                Slider(value: Binding(get: { model.air ?? 0 }, set: { model.dragAir($0) }),
                       in: SingStyle.airRange,
                       onEditingChanged: { editing in if !editing { model.commitAir() } })
                    .controlSize(.small)
                    .tint(DAWTheme.playback)
                    .frame(maxWidth: 200)
                Text(SingCopy.airLots)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .help(SingCopy.airHelp)
            Toggle(isOn: Binding(get: { model.followsVelocity }, set: { model.setFollowVelocity($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(SingCopy.followLoudness)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DAWTheme.textPrimary)
                    Text(model.followDisabledReason ?? SingCopy.followLoudnessHelp)
                        .font(.system(size: 9.5))
                        .foregroundStyle(DAWTheme.textDim)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DAWTheme.playback)
            .disabled(model.followDisabledReason != nil)
            HStack(spacing: 8) {
                Text(model.selectionLine == nil ? SingCopy.pickNotesHint : SingCopy.notesSelected(model.selectedNoteIDs.count))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if model.selectionLine != nil {
                    SingButton(title: SingCopy.clearSelection) { model.clearSelection() }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DAWTheme.textSecondary)
            .frame(width: 92, alignment: .leading)
    }
}

/// The Harmony card (§4.1): [Add a harmony] with §14's choices ("Sing the chord's other notes" only when the tune
/// has chords), one row per part (name, voice, range line, [Remove]), up to three, and the key they are counted in.
/// [Sing it] sings the lead and every part in ONE job.
struct SingHarmonyCardView: View {
    var model: SingSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SingSectionLabel(text: SingCopy.harmonySection)
                Spacer(minLength: 4)
                addMenu
            }
            if let line = model.harmonyKey.line {
                HStack(spacing: 8) {
                    if model.harmonyKey == .unknown {
                        PanelRefusalLine(message: line)
                    } else {
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(DAWTheme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    keyMenu
                }
            }
            ForEach(model.harmonyRows) { row in partRow(row) }
            if let reason = model.addHarmonyDisabledReason {
                SingSentence(text: reason, color: DAWTheme.textDim, size: 10)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(Array(model.harmonyChoices.enumerated()), id: \.offset) { _, choice in
                Button(choice.title) { model.addHarmony(choice) }
            }
            Menu(SingCopy.harmonyOtherMelody) {
                if model.otherMelodies.isEmpty {
                    Text(SingCopy.noOtherMelody)
                } else {
                    ForEach(model.otherMelodies) { other in
                        Button(other.title) { model.addHarmony(.otherMelody(clipID: other.id)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 8.5, weight: .bold))
                Text(SingCopy.addHarmony)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.addHarmonyDisabledReason != nil)
        .help(model.addHarmonyDisabledReason ?? SingCopy.addHarmony)
    }

    private var keyMenu: some View {
        Menu {
            Button(SingCopy.keyFromSong) { model.setHarmonyKey(nil) }
            Divider()
            ForEach(KeyMode.allCases, id: \.self) { mode in
                ForEach(0..<12, id: \.self) { tonic in
                    let key = SongKey(tonicPitchClass: tonic, mode: mode)
                    Button(key.name) { model.setHarmonyKey(key) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(SingCopy.pickKey)
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .foregroundStyle(DAWTheme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func partRow(_ row: SingHarmonyRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DAWTheme.textPrimary)
                Menu {
                    ForEach(model.voices) { choice in
                        Button(choice.name) { model.setHarmonyVoice(row.id, voiceID: choice.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(row.voiceName)
                            .font(.system(size: 10))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(DAWTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer(minLength: 4)
                SingButton(title: SingCopy.removePart) { model.removeHarmony(row.id) }
            }
            if let refusal = row.refusal {
                PanelRefusalLine(message: refusal)
            } else if let line = row.rangeLine {
                SingSentence(text: line, color: row.fits ? DAWTheme.textSecondary : DAWTheme.record, size: 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.ai.opacity(0.25), lineWidth: 1))
    }
}
