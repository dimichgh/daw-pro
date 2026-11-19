import Foundation
import Observation
import DAWCore

// m39-tpl-8 — THE TEMPLATE PICKER, the `@MainActor` half
// (docs/design/2026-09-27-multi-instrument-templates.md §9).
//
// `TemplatePickerState` (pure, nonisolated, tested without a store) decides what
// the card shows. This class does the four things that need the live song:
// reads its facts, runs the store's OWN dry runs on the selection, runs the
// presses, and keeps the fading notice. SwiftUI is thin over it
// (`Sources/DAWApp/TemplatePicker/`).
//
// ⭐ THERE IS NO UI-ONLY PATH (§9.4). Every mutation below is ONE call to the
// store function a wire verb makes, with the arguments that verb passes:
//
//   "Start a song"      → `applySongSkeleton(genre:template:)`  (`macro.songSkeleton {genre, template}`)
//   "Add to my song"    → `applyTemplate(_:)`                  (`template.apply {template}`)
//   Save as Template    → `saveTemplate(name:trackIDs:library:)` (`template.save`)
//   Import / Export     → `importTemplate` / `exportTemplate`  (`template.import` / `template.export`)
//   Remove              → `removeTemplate(id:library:)`        (`template.remove`)
//   the dry runs        → `applyTemplate(_:dryRun: true)` / `planSongSkeleton` (`dryRun: true`)
//
// Undo is therefore the store's: one press is one undo step ("Add Template
// '<name>'", or "Song Skeleton '<Genre>' with '<name>'"), proven in the store's
// own suites and re-checked through this class by the appended tests.
//
// ⭐ NO `try?` ON THIS PATH (§9.3: "Every refusal from the store is shown in the
// card in the store's own words"). Every `catch` keeps the error's
// `errorDescription` — exactly the text the wire sends (`Commands.swift`'s
// `LocalizedError` catch) — and puts it on the card.
//
// TODO(TPL-8 dogfood): no `debug.templatePicker` staging seam exists yet, so a
// headless capture cannot open this card; the §8.9 dogfood drives it by hand.

/// The fading notice after a template lands (§9.2) or is saved.
public struct TemplatePickerNotice: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
}

@MainActor
@Observable
public final class TemplatePickerModel {
    /// The template the card selects when it opens: the Sketchpad's USE A
    /// TEMPLATE button promises a pop song on one press of Return (§9.1).
    public static let defaultTemplateID = "pop-band"
    /// The card's stable Simple/Pro density key (`PanelDensityStore`).
    public static let panelID = "templatePicker"
    /// How long the notice stays before it fades on its own.
    public static let noticeSeconds: Double = 8

    /// The picker card, or nil when it is closed.
    public private(set) var state: TemplatePickerState?
    /// The Save as Template card, or nil. Shown INSTEAD of the picker while
    /// open (one centered card at a time).
    public private(set) var saveSheet: TemplateSaveSheetState?
    /// The fading notice, or nil.
    public private(set) var notice: TemplatePickerNotice?

    @ObservationIgnored public let store: ProjectStore
    /// The saved-templates folder. The app passes `.standard`, the folder every
    /// wire verb uses; tests pass their own.
    @ObservationIgnored public let library: TemplateLibrary
    @ObservationIgnored private var noticeSeq = 0

    public init(store: ProjectStore, library: TemplateLibrary = .standard) {
        self.store = store
        self.library = library
    }

    /// A card (the picker or the save card) is up — a scrimmed modal that
    /// `AppModel.isModalPresented` must list.
    public var isOpen: Bool { state != nil || saveSheet != nil }

    // MARK: - Opening and closing

    /// Opens the picker with `id` selected (if it is on offer).
    public func open(preselecting id: String? = TemplatePickerModel.defaultTemplateID, isPro: Bool) {
        var fresh = TemplatePickerState(listing: store.listTemplates(library: library), isPro: isPro,
                                        facts: currentFacts())
        fresh.selectedID = fresh.defaultSelection(preferring: id)
        fresh.preflight = preflight(for: fresh)
        saveSheet = nil
        state = fresh
    }

    public func close() {
        state = nil
        saveSheet = nil
    }

    // MARK: - Choosing

    /// Selects a tile. The last library line and a pending Remove belonged to
    /// the previous selection, so they go.
    public func select(_ id: String) {
        update { picker in
            picker.selectedID = id
            picker.songStyleChoice = nil
            picker.libraryLine = nil
            picker.pendingRemovalID = nil
        }
    }

    public func setTab(_ tab: TemplatePickerTab) {
        update { picker in
            picker.tab = tab
            picker.selectedID = picker.defaultSelection(preferring: picker.selectedID)
            picker.songStyleChoice = nil
            picker.libraryLine = nil
            picker.pendingRemovalID = nil
        }
    }

    /// The density chip moved (the view reads `PanelDensityStore`).
    public func setPro(_ isPro: Bool) {
        guard state?.isPro != isPro else { return }
        update { picker in
            picker.isPro = isPro
            picker.selectedID = picker.defaultSelection(preferring: picker.selectedID)
        }
    }

    public func setSongStyle(_ genre: String) {
        update { $0.songStyleChoice = genre }
    }

    /// The song changed under the card (tracks added, recording started, a new
    /// tempo): re-read its facts and re-run the dry runs.
    public func refreshFacts() {
        guard state != nil else { return }
        update { $0.facts = currentFacts() }
    }

    // MARK: - Pressing (§9.2)

    /// What Return does: the primary button, only while it is enabled (a
    /// disabled default button does not answer Return).
    @discardableResult
    public func pressPrimary() -> Bool {
        guard let state, state.button(state.primaryAction)?.isEnabled == true else { return false }
        return press(state.primaryAction)
    }

    /// Runs `action` through its ONE store call. On success the card closes and
    /// the notice appears; on a refusal the card stays open and shows the
    /// store's sentence, verbatim, and nothing in the song changed (the store's
    /// guarantee).
    @discardableResult
    public func press(_ action: TemplatePickerAction) -> Bool {
        guard var picker = state, let entry = picker.selectedEntry else { return false }
        let template = entry.template
        let text: String
        do {
            switch action {
            case .startSong:
                guard let genre = picker.startGenre else { return false }
                let result = try store.applySongSkeleton(genre: genre, template: template)
                text = TemplatePickerCopy.startedNotice(
                    name: template.name, trackCount: result.templateKeys.count, tempoBPM: result.tempoBPM)
            case .addToSong:
                let result = try store.applyTemplate(template)
                text = TemplatePickerCopy.addedNotice(name: template.name, trackCount: result.tracks.count)
            }
        } catch {
            picker.pressRefusal = Self.storeWords(error)
            state = picker
            return false
        }
        state = nil
        show(text)
        return true
    }

    // MARK: - The library (Pro, §9.2)

    /// `template.import {path}`, then My Templates with the new one selected.
    public func importTemplate(fromPath path: String) {
        guard state != nil else { return }
        do {
            let result = try store.importTemplate(from: path, library: library)
            reload(selecting: result.id, tab: .saved,
                   line: .init(tone: .info, text: ([TemplatePickerCopy.importedLine(name: result.name)]
                                                    + result.warnings.map(\.message)).joined(separator: " ")))
        } catch {
            update { $0.libraryLine = .init(tone: .caution, text: Self.storeWords(error)) }
        }
    }

    /// `template.export {id, path, overwrite}`. The save panel has already asked
    /// before replacing a file, so it passes `overwrite: true`.
    public func exportSelected(toPath path: String) {
        guard let entry = state?.selectedEntry else { return }
        do {
            let result = try store.exportTemplate(id: entry.id, to: path, overwrite: true, library: library)
            update { $0.libraryLine = .init(tone: .info, text: TemplatePickerCopy.exportedLine(path: result.path)) }
        } catch {
            update { $0.libraryLine = .init(tone: .caution, text: Self.storeWords(error)) }
        }
    }

    /// First press of Remove: ask, because deleting a file has no undo.
    public func requestRemoveSelected() {
        guard let state, state.canRemove, let id = state.selectedEntry?.id else { return }
        update { $0.pendingRemovalID = id }
    }

    public func cancelRemove() {
        update { $0.pendingRemovalID = nil }
    }

    /// `template.remove {id}`.
    public func confirmRemove() {
        guard let id = state?.pendingRemovalID else { return }
        let name = state?.listing.entry(id: id)?.name ?? id
        do {
            try store.removeTemplate(id: id, library: library)
            reload(selecting: nil, tab: .saved,
                   line: .init(tone: .info, text: TemplatePickerCopy.removedLine(name: name)))
        } catch {
            update {
                $0.pendingRemovalID = nil
                $0.libraryLine = .init(tone: .caution, text: Self.storeWords(error))
            }
        }
    }

    // MARK: - Save as Template (§7.2)

    /// Opens the Save as Template card over the song's tracks, `checked` ticked.
    /// `fromPicker`: after saving, come back to the picker on My Templates.
    public func openSaveSheet(checking checked: Set<UUID>, fromPicker: Bool) {
        saveSheet = TemplateSaveSheetState(
            rows: TemplateSaveSheetState.rows(for: store.tracks, checked: checked),
            returnsToPicker: fromPicker && state != nil)
        if !fromPicker { state = nil }
    }

    public func setSaveName(_ name: String) {
        guard saveSheet != nil else { return }
        saveSheet?.name = name
        saveSheet?.refusal = nil
    }

    public func toggleSaveTrack(_ id: UUID) {
        guard let index = saveSheet?.rows.firstIndex(where: { $0.id == id }) else { return }
        saveSheet?.rows[index].isChecked.toggle()
        saveSheet?.refusal = nil
    }

    /// Back to the picker (when it opened this card), else closed.
    public func cancelSave() {
        saveSheet = nil
    }

    /// `template.save {name, trackIds}`. Writes a file, makes no undo entry.
    @discardableResult
    public func save() -> Bool {
        guard var sheet = saveSheet, sheet.canSave else { return false }
        do {
            let result = try store.saveTemplate(name: sheet.trimmedName, trackIDs: sheet.chosenTrackIDs,
                                                library: library)
            saveSheet = nil
            let saved = TemplatePickerCopy.savedNotice(name: result.name,
                                                        trackCount: result.template.tracks.count)
            let text = ([saved] + result.warnings.map(\.message)).joined(separator: " ")
            if sheet.returnsToPicker, state != nil {
                reload(selecting: result.id, tab: .saved, line: .init(tone: .info, text: text))
            } else {
                show(text)
            }
            return true
        } catch {
            sheet.refusal = Self.storeWords(error)
            saveSheet = sheet
            return false
        }
    }

    // MARK: - The notice

    /// Removes the notice if it is still the one with `id` (a newer one stays).
    public func dismissNotice(id: Int) {
        if notice?.id == id { notice = nil }
    }

    private func show(_ text: String) {
        noticeSeq += 1
        notice = TemplatePickerNotice(id: noticeSeq, text: text)
    }

    // MARK: - Internals

    /// The store's sentence for a refusal: exactly what the wire sends.
    nonisolated static func storeWords(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func currentFacts() -> TemplatePickerFacts {
        TemplatePickerFacts(songHasTracks: !store.tracks.isEmpty,
                            isRecording: store.transport.isRecording,
                            tempoBPM: store.transport.tempoBPM)
    }

    /// Applies a change to the open card, clears the last press's refusal (it
    /// described a state that has now changed), and re-runs the dry runs.
    private func update(_ change: (inout TemplatePickerState) -> Void) {
        guard var picker = state else { return }
        change(&picker)
        picker.pressRefusal = nil
        picker.preflight = preflight(for: picker)
        state = picker
    }

    private func reload(selecting id: String?, tab: TemplatePickerTab, line: TemplatePickerMessage) {
        update { picker in
            picker.listing = store.listTemplates(library: library)
            picker.tab = tab
            picker.pendingRemovalID = nil
            picker.selectedID = picker.defaultSelection(preferring: id)
            picker.songStyleChoice = nil
            picker.libraryLine = line
        }
    }

    /// The store's own dry runs on the selection — the two the wire's
    /// `dryRun: true` makes — plus the pure builder's routing and plug-in facts.
    /// Changes nothing in the song.
    private func preflight(for picker: TemplatePickerState) -> TemplatePickerPreflight? {
        guard let entry = picker.selectedEntry, let genre = picker.startGenre else { return nil }
        let template = entry.template
        var hasRouting: Bool?
        var plugIns: [TemplatePickerPreflight.PlugIn] = []
        do {
            let plan = try TemplateBuilder.plan(template)
            hasRouting = plan.hasRouting
            // A template file carries an Audio Unit's component code, not its
            // name (the codec's keys are type/subType/manufacturer/state), so an
            // INSTALLED plug-in is named from this Mac's own list; a missing one
            // can only be named by its code — the label the store's warning uses.
            var installed: [AudioUnitComponentInfo]?
            for resource in plan.resources {
                switch resource.item {
                case .audioUnitInstrument(let unit), .audioUnitEffect(let unit):
                    if installed == nil {
                        installed = store.availableAudioUnits() + store.availableAudioUnitEffects()
                    }
                    let known = installed?.first { $0.component == unit.component }?.name
                    plugIns.append(.init(path: resource.path, name: Self.plugInName(unit, installedName: known)))
                case .soundBank, .samplerZones:
                    break
                }
            }
        } catch {
            // Not swallowed: both dry runs below run this same builder first and
            // report its refusal, in its words, as the reason each button is off.
            hasRouting = nil
        }
        var warnings = entry.warnings
        var addRefusal: String?
        var startRefusal: String?
        var startTempo = SongSkeletonCatalog.genre(named: genre)?.defaultTempoBPM
        do {
            warnings += try store.applyTemplate(template, dryRun: true).warnings
        } catch {
            addRefusal = Self.storeWords(error)
        }
        do {
            let plan = try store.planSongSkeleton(genre: genre, template: template)
            warnings += plan.warnings
            startTempo = plan.tempoBPM
        } catch {
            startRefusal = Self.storeWords(error)
        }
        var seen: Set<String> = []
        warnings = warnings.filter { seen.insert("\($0.code.rawValue)|\($0.path)|\($0.message)").inserted }
        return TemplatePickerPreflight(
            templateID: entry.id, genre: genre, hasRouting: hasRouting, startRefusal: startRefusal,
            addRefusal: addRefusal, warnings: warnings, plugIns: plugIns, startTempoBPM: startTempo)
    }

    /// A plug-in's name: the one it carries, else this Mac's name for it, else
    /// its component code — the label the store's own warning falls back to.
    nonisolated static func plugInName(_ unit: AudioUnitConfig, installedName: String?) -> String {
        if !unit.name.isEmpty { return unit.name }
        if let installedName, !installedName.isEmpty { return installedName }
        let component = unit.component
        return "\(component.type)/\(component.subType)/\(component.manufacturer)"
    }
}
