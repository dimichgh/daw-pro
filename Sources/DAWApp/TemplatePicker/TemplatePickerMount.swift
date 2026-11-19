import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DAWCore
import DAWAppKit

// m39-tpl-8 — where the template picker meets the app: the doors that open it,
// the file panels its Pro row needs, and the mount `ContentView.pickerOverlays`
// places (the `TuneToMelodyCardMount` shape: one line there, everything here).
//
// Every door opens the SAME `AppModel.templatePicker`; every press inside it is a
// `TemplatePickerModel` method making the store call its wire verb makes
// (design §9.4: no UI-only path).

extension AppModel {
    /// The Sketchpad's USE A TEMPLATE button and the add-track (+) menu's "Add a
    /// Band from a Template…": the picker, with Pop Band selected (§9.1), in the
    /// density the person last left it in.
    func openTemplatePicker(preselecting id: String? = TemplatePickerModel.defaultTemplateID) {
        templatePicker.open(
            preselecting: id,
            isPro: panelDensity.density(forPanel: TemplatePickerModel.panelID) == .pro)
    }

    /// A track header's "Save Track as Template…": the Save card with that track
    /// ticked. Closes with a notice; the picker is not opened behind it.
    func openSaveTrackAsTemplate(trackID: UUID) {
        templatePicker.openSaveSheet(checking: [trackID], fromPicker: false)
    }

    /// Pro's Import…: an open panel for one `.dawtemplate`, then `template.import`.
    func importTemplateViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.allowedContentTypes = [Self.templateFileType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        templatePicker.importTemplate(fromPath: url.path)
    }

    /// Pro's Export…: a save panel (which itself asks before replacing a file),
    /// then `template.export`.
    func exportTemplateViaPanel() {
        guard let entry = templatePicker.state?.selectedEntry else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(entry.name).\(TemplateLibrary.fileExtension)"
        panel.prompt = "Export"
        panel.allowedContentTypes = [Self.templateFileType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        templatePicker.exportSelected(toPath: url.path)
    }

    /// `.dawtemplate`: a dynamic type from the extension (the app declares no
    /// exported type for it), falling back to plain JSON.
    static var templateFileType: UTType {
        UTType(filenameExtension: TemplateLibrary.fileExtension) ?? .json
    }
}

/// The picker card, the Save card and the fading notice, drawn from
/// `AppModel.templatePicker`. Always present in `pickerOverlays`, drawing
/// nothing while closed.
struct TemplatePickerCardMount: View {
    let model: AppModel

    private var picker: TemplatePickerModel { model.templatePicker }

    var body: some View {
        let store = model.store
        ZStack {
            if picker.isOpen {
                GeometryReader { geo in
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                            .ignoresSafeArea()
                            // A click beside the picker closes it (nothing is lost);
                            // beside the Save card it does nothing (a typed name is).
                            .onTapGesture {
                                if picker.saveSheet == nil {
                                    withAnimation(.easeOut(duration: 0.15)) { picker.close() }
                                }
                            }
                        if let sheet = picker.saveSheet {
                            TemplatePickerSaveSheet(picker: picker, sheet: sheet,
                                                    availableHeight: geo.size.height)
                        } else if let state = picker.state {
                            TemplatePickerCard(
                                picker: picker, state: state, densityStore: model.panelDensity,
                                availableHeight: geo.size.height,
                                onImport: { model.importTemplateViaPanel() },
                                onExport: { model.exportTemplateViaPanel() },
                                onSaveAsTemplate: {
                                    picker.openSaveSheet(checking: model.activeTrackID.map { [$0] } ?? [],
                                                         fromPicker: true)
                                },
                                onClose: { withAnimation(.easeOut(duration: 0.15)) { picker.close() } })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
            if let notice = picker.notice {
                noticeView(notice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 84)
                    // Rule 4: a notice that leaves on its own fades out slower than it came.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.15)),
                        removal: .opacity.animation(.easeOut(duration: 0.3))))
                    .task(id: notice.id) {
                        do {
                            try await Task.sleep(for: .seconds(TemplatePickerModel.noticeSeconds))
                        } catch {
                            return  // the notice was replaced or the view went away
                        }
                        picker.dismissNotice(id: notice.id)
                    }
            }
        }
        // The density chip lives on the card; the model follows it.
        .onChange(of: model.panelDensity.density(forPanel: TemplatePickerModel.panelID)) { _, density in
            picker.setPro(density == .pro)
        }
        // The song can change under an open card (a wire call, a take starting):
        // the buttons and their reasons follow it.
        .onChange(of: store.transport.isRecording) { _, _ in picker.refreshFacts() }
        .onChange(of: store.tracks.count) { _, _ in picker.refreshFacts() }
        .onChange(of: store.transport.tempoBPM) { _, _ in picker.refreshFacts() }
    }

    private func noticeView(_ notice: TemplatePickerNotice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.signal)
            Text(notice.text)
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { picker.dismissNotice(id: notice.id) }
        .help("Click to dismiss")
    }
}
