import SwiftUI
import DAWCore
import DAWAppKit

/// The Save as Template card (m39-tpl-8, design §7.2, §9.1): a name, the song's
/// tracks with a tick each, and Save. One centered card at a time — it replaces
/// the picker while it is up, and comes back to it on Cancel when the picker
/// opened it.
///
/// Save runs `ProjectStore.saveTemplate(name:trackIDs:library:)` through
/// `TemplatePickerModel.save()` — the `template.save` verb's own call. It writes a
/// file and makes NO undo step. The card itself refuses only what it can see (no
/// name, no ticked track); every other rule — a name over 40 characters, too many
/// tracks, a file too big — is the store's, and its sentence is shown verbatim.
///
/// The track list is the region that yields (the m26-i law): it hugs its rows
/// when they fit and scrolls inside `TemplatePickerLayout.saveListRoom`.
/// Return saves (`.defaultAction`); no Escape binding (the `.cancelAction`
/// census in `EscapeKeyMonitorSiteTests`); Cancel and ✕ close. The scrim does
/// NOT close it: a click that misses the card must not throw away a typed name.
struct TemplatePickerSaveSheet: View {
    let picker: TemplatePickerModel
    let sheet: TemplateSaveSheetState
    var availableHeight: CGFloat

    private typealias W = TemplatePickerCopy
    private typealias L = TemplatePickerLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 6) {
                label(W.saveNameLabel)
                TextField(W.saveNamePlaceholder, text: Binding(
                    get: { sheet.name },
                    set: { picker.setSaveName($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(DAWTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                label(W.saveTracksLabel)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sheet.rows) { row in
                            trackRow(row)
                        }
                    }
                }
                .frame(maxHeight: L.saveListRoom(availableHeight: availableHeight))
                .fixedSize(horizontal: false, vertical: true)
                Text(W.saveBusNote)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
            footer
        }
        .padding(16)
        .frame(width: L.saveCardWidth, alignment: .leading)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(W.saveTitle)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(DAWTheme.textPrimary)
                Text(W.saveSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { picker.cancelSave() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close without saving")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
    }

    private func trackRow(_ row: TemplateSaveSheetState.Row) -> some View {
        Button { picker.toggleSaveTrack(row.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: row.isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(row.isChecked ? DAWTheme.playback : DAWTheme.textDim)
                Image(systemName: Self.kindSymbol(row.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 14)
                Text(row.name)
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: L.saveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func kindSymbol(_ kind: TrackKind) -> String {
        switch kind {
        case .instrument: return "pianokeys"
        case .audio: return "waveform"
        case .bus: return "arrow.triangle.merge"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let refusal = sheet.refusal {
                PanelRefusalLine(message: refusal)
            } else if let reason = sheet.disabledReason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { picker.cancelSave() } label: {
                    Text(W.saveCancel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { picker.save() } label: {
                    Text(W.saveButton)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(sheet.canSave ? DAWTheme.background : DAWTheme.textDim)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(sheet.canSave ? DAWTheme.textPrimary : DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!sheet.canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
