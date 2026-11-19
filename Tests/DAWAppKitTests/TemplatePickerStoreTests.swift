import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

// m39-tpl-8 — the template picker against a REAL `ProjectStore`
// (docs/design/2026-09-27-multi-instrument-templates.md §9.3, §9.4).
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite `SketchpadModelTests`, not a
// new suite: `MainActorOccupancySiteTests` Leg C caps `@MainActor` `@Suite`s and
// the cap is full (the `SkeletonGoldenTests` → `SongSkeletonTests` precedent).
// Every helper carries a `tpl8` prefix so it cannot collide with the suite's own.
//
// ⭐ WHAT "THE SAME STORE CALL THE WIRE MAKES" MEANS HERE, AND HOW IT IS PROVEN.
// This target cannot import DAWControl, so the wire is not re-run here. The proof
// has two halves:
//   1. (READ, not re-run by this lane) `Commands.swift`'s `macro.songSkeleton`
//      case calls `store.applySongSkeleton(genre:tempoBPM:sections:tracks:template:)`
//      with nil tempo/sections/tracks and the id resolved through
//      `TemplateLibrary.standard.entry(id:)`; `template.apply` calls
//      `store.applyTemplate(_:dryRun:)`. `MacroSkeletonCommandTests` and
//      `TemplateWireCommandTests` pin that half.
//   2. (here) a press through the picker leaves a song that is STRUCTURALLY
//      IDENTICAL (every id renamed by first appearance) to a twin store given
//      exactly that call, AND the undo label names that call — "Song Skeleton
//      'Pop' with 'Pop Band'" tells it apart from the old Sketchpad body
//      (`applySongSkeleton(genre: "pop")`, "Song Skeleton 'Pop'") and from
//      `applyTemplate` ("Add Template 'Pop Band'").
extension SketchpadModelTests {

    // MARK: - Helpers

    /// A fresh, empty saved-templates folder of this test's own.
    static func tpl8Library() -> TemplateLibrary {
        TemplateLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("DAWPro-tpl8-\(UUID().uuidString)", isDirectory: true))
    }

    /// Writes `template` into `library` as a saved file, the canonical way.
    static func tpl8Write(_ template: TrackSetTemplate, into library: TemplateLibrary) throws {
        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        try TemplateCapture.canonicalJSON(template)
            .write(to: library.root.appendingPathComponent("\(template.id).dawtemplate"))
    }

    static func tpl8BuiltIn(_ id: String) throws -> TrackSetTemplate {
        try #require(BuiltInTemplateCatalog.load().templates.first { $0.id == id }).template
    }

    /// The song as JSON with every UUID renamed by order of first appearance, so
    /// two songs built by the same calls compare equal although every id is fresh.
    static func tpl8Shape(_ store: ProjectStore) throws -> String {
        struct Song: Encodable {
            let tracks: [Track]
            let markers: [Marker]
            let transport: TransportState
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(
            Song(tracks: store.tracks, markers: store.markers, transport: store.transport)), as: UTF8.self)
        let pattern = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        var names: [String: String] = [:]
        var out = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[cursor..<range.lowerBound]
            let uuid = String(text[range]).uppercased()
            if names[uuid] == nil { names[uuid] = "#\(names.count)" }
            out += names[uuid] ?? "?"
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// The onboarding tour's "project gained content" test, verbatim
    /// (`OnboardingSignalAdapter.hasContent`, DAWApp, which no test target sees).
    static func tpl8HasContent(_ store: ProjectStore) -> Bool {
        store.tracks.contains { !$0.clips.isEmpty }
    }

    /// The store's own refusal sentence for `body`, as the wire would send it.
    static func tpl8StoreWords(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Return on Pop Band = the wire's call

    @Test("m39-tpl-8: Return on the Sketchpad's Pop Band runs the wire's macro.songSkeleton call — same song, same undo label, ONE undo step, and the tour's content signal fires")
    func tpl8ReturnStartsTheWiresPopSong() throws {
        let store = ProjectStore()
        let picker = TemplatePickerModel(store: store, library: Self.tpl8Library())
        picker.open(isPro: false)
        let state = try #require(picker.state)
        #expect(state.selectedID == "pop-band", "the Sketchpad opens the picker with Pop Band selected")
        #expect(state.primaryAction == .startSong)
        #expect(state.button(.startSong)?.isEnabled == true, "\(state.messages)")
        #expect(!Self.tpl8HasContent(store), "POSITIVE CONTROL: an empty song has no content yet")

        #expect(picker.pressPrimary(), "Return (the primary) must run")

        let twin = ProjectStore()
        let wire = try twin.applySongSkeleton(genre: "pop", tempoBPM: nil, sections: nil, tracks: nil,
                                              template: try Self.tpl8BuiltIn("pop-band"))
        #expect(store.undoLabel == "Song Skeleton 'Pop' with 'Pop Band'")
        #expect(store.undoLabel == twin.undoLabel)
        #expect(try Self.tpl8Shape(store) == Self.tpl8Shape(twin), "the picker built a different song than the wire's call")
        #expect(picker.state == nil, "the card closes once the song lands")
        #expect(picker.notice?.text == TemplatePickerCopy.startedNotice(
            name: "Pop Band", trackCount: wire.templateKeys.count, tempoBPM: wire.tempoBPM))
        #expect(Self.tpl8HasContent(store), "the onboarding step's `projectGainedContent` must still fire")

        // ONE undo step takes the whole thing away.
        _ = try store.undo()
        #expect(store.tracks.isEmpty && store.markers.isEmpty)
        #expect(!store.canUndo, "a second undo step was recorded")
    }

    @Test("m39-tpl-8: in a song with tracks, Return adds the band through template.apply's call — existing tracks untouched, tempo kept, one undo step")
    func tpl8ReturnAddsToASongWithTracks() throws {
        let existing = Track(name: "My Guitar", kind: .audio)
        let store = ProjectStore(tracks: [existing])
        let twin = ProjectStore(tracks: [existing])
        let picker = TemplatePickerModel(store: store, library: Self.tpl8Library())
        picker.open(preselecting: "lofi-chill", isPro: false)
        #expect(picker.state?.primaryAction == .addToSong)
        #expect(picker.pressPrimary())

        _ = try twin.applyTemplate(try Self.tpl8BuiltIn("lofi-chill"))
        #expect(store.undoLabel == "Add Template 'Lo-Fi Chill'")
        #expect(try Self.tpl8Shape(store) == Self.tpl8Shape(twin))
        #expect(store.tracks.first == existing, "an existing track changed")
        #expect(store.transport.tempoBPM == TransportState().tempoBPM, "Add to my song never re-tempos")
        #expect(picker.notice?.text == TemplatePickerCopy.addedNotice(name: "Lo-Fi Chill", trackCount: 6))
        _ = try store.undo()
        #expect(store.tracks == [existing])
    }

    // MARK: - Refusals, in the store's words

    @Test("m39-tpl-8: a refusal reaches the card in the STORE's words, before the press and on it — the card stays open and the song does not change")
    func tpl8RefusalIsTheStoresSentence() throws {
        let library = Self.tpl8Library()
        let missing = TrackSetTemplate(id: "user-tpl8-missing", name: "Missing Bank", songForm: "pop", tracks: [
            TemplateTrack(key: "strings", name: "Strings", kind: .instrument, instrument: InstrumentDescriptor(
                kind: .soundBank, soundBank: SoundBankConfig(source: .file(path: "/nowhere/tpl8-missing.sf2"),
                                                             program: 48))),
        ])
        try Self.tpl8Write(missing, into: library)
        let store = ProjectStore()
        let words = try #require(Self.tpl8StoreWords { _ = try ProjectStore().applyTemplate(missing) },
                                 "POSITIVE CONTROL: the store must refuse this template")
        #expect(words.contains("/nowhere/tpl8-missing.sf2"), "\(words)")

        let picker = TemplatePickerModel(store: store, library: library)
        picker.open(preselecting: missing.id, isPro: true)
        picker.setTab(.saved)
        let before = try Self.tpl8Shape(store)
        let state = try #require(picker.state)
        #expect(state.selectedID == missing.id)
        // Before the press: the button is off with the store's sentence.
        #expect(state.button(.addToSong)?.disabledReason == words)
        #expect(state.messages.contains(.init(tone: .caution, text: words)))
        #expect(!picker.pressPrimary(), "Return on a refused primary must do nothing")

        // On the press: the same sentence, from the store's own throw.
        #expect(!picker.press(.addToSong))
        #expect(picker.state?.pressRefusal == words)
        #expect(picker.state?.messages.first == .init(tone: .caution, text: words))
        #expect(picker.state != nil, "the card must stay open on a refusal")
        #expect(picker.notice == nil)
        #expect(try Self.tpl8Shape(store) == before, "a refusal changed the song")
        #expect(!store.canUndo, "a refusal recorded an undo step")
    }

    @Test("m39-tpl-8: while recording, a connected template is off with §9.3's sentence and a forced press gets the store's own refusal; a plain one still adds")
    func tpl8RecordingGuard() throws {
        var transport = TransportState()
        transport.isRecording = true
        let library = Self.tpl8Library()
        let plain = TrackSetTemplate(id: "user-tpl8-plain", name: "Just Keys", songForm: "pop", tracks: [
            TemplateTrack(key: "keys", name: "Keys", kind: .instrument, instrument: InstrumentDescriptor(
                kind: .soundBank, soundBank: SoundBankConfig(source: .generalMIDI, program: 0))),
        ])
        try Self.tpl8Write(plain, into: library)
        let store = ProjectStore(tracks: [Track(name: "Take", kind: .audio)], transport: transport)
        let picker = TemplatePickerModel(store: store, library: library)
        picker.open(preselecting: "lofi-chill", isPro: true)
        let state = try #require(picker.state)
        #expect(state.button(.addToSong)?.disabledReason == "Stop recording to add this band.")
        #expect(state.button(.startSong)?.disabledReason == "Stop recording to add this band.")

        let words = try #require(Self.tpl8StoreWords {
            _ = try ProjectStore(transport: transport).applyTemplate(try Self.tpl8BuiltIn("lofi-chill"))
        })
        #expect(!picker.press(.addToSong))
        #expect(picker.state?.pressRefusal == words, "the store's sentence, verbatim")

        picker.setTab(.saved)
        picker.select(plain.id)
        #expect(picker.state?.button(.addToSong)?.isEnabled == true, "\(picker.state?.messages ?? [])")
        #expect(picker.press(.addToSong), "a template of plain tracks adds mid-take")
        #expect(store.undoLabel == "Add Template 'Just Keys'")
    }

    // MARK: - States the card must show (§9.3)

    @Test("m39-tpl-8: a saved template with no song form starts a song in the chosen Song style")
    func tpl8SongStyleReachesTheStore() throws {
        let library = Self.tpl8Library()
        let noForm = TrackSetTemplate(id: "user-tpl8-noform", name: "No Form", genres: ["jazz"], tracks: [
            TemplateTrack(key: "keys", name: "Keys", kind: .instrument, instrument: InstrumentDescriptor(
                kind: .soundBank, soundBank: SoundBankConfig(source: .generalMIDI, program: 0))),
        ])
        try Self.tpl8Write(noForm, into: library)
        let store = ProjectStore()
        let picker = TemplatePickerModel(store: store, library: library)
        picker.open(preselecting: noForm.id, isPro: true)
        picker.setTab(.saved)
        picker.select(noForm.id)
        #expect(picker.state?.songStyleMenu?.selectedGenre == "jazz")
        picker.setSongStyle("reggae")
        #expect(picker.press(.startSong))
        #expect(store.undoLabel == "Song Skeleton 'Reggae' with 'No Form'")
        #expect(store.transport.tempoBPM == SongSkeletonCatalog.genre(named: "reggae")?.defaultTempoBPM)
    }

    @Test("m39-tpl-8: an unreadable saved file is listed greyed with the library's reason, never skipped")
    func tpl8UnreadableIsShown() throws {
        let library = Self.tpl8Library()
        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: library.root.appendingPathComponent("broken.dawtemplate"))
        let listing = library.list()
        let reason = try #require(listing.unreadable.first { $0.file == "broken.dawtemplate" }?.message,
                                  "POSITIVE CONTROL: the library itself lists the file as unreadable")
        let picker = TemplatePickerModel(store: ProjectStore(), library: library)
        picker.open(isPro: true)
        picker.setTab(.saved)
        #expect(picker.state?.unreadableTiles == [.init(file: "broken.dawtemplate", source: .saved, reason: reason)])
    }

    @Test("m39-tpl-8: a plug-in this Mac lacks is named before the press, from the store's own dry run")
    func tpl8MissingPlugInIsNamed() throws {
        let library = Self.tpl8Library()
        let synth = AudioUnitConfig(component: AudioUnitComponentID(subType: "tpl8", manufacturer: "none"),
                                    name: "Ghost Synth")
        let template = TrackSetTemplate(id: "user-tpl8-au", name: "Ghost", songForm: "pop", tracks: [
            TemplateTrack(key: "au", name: "Ghost", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .audioUnit, audioUnit: synth)),
        ])
        try Self.tpl8Write(template, into: library)
        let picker = TemplatePickerModel(store: ProjectStore(), library: library)
        picker.open(preselecting: template.id, isPro: true)
        picker.setTab(.saved)
        picker.select(template.id)
        // ⚠️ A template FILE keeps the component code, not the name (the codec's
        // Audio Unit keys are type/subType/manufacturer/state), so a plug-in this
        // Mac lacks can only be named by its code — the store's own warning
        // falls back to the same label.
        let messages = try #require(picker.state?.messages)
        #expect(messages.contains(.init(tone: .caution,
            text: "aumu/tpl8/none isn't installed on this Mac. The track will be added without its sound.")),
            "\(messages)")
        let saved = try #require(library.list().entry(id: template.id))
        let dryRun = try ProjectStore().applyTemplate(saved.template, dryRun: true)
        let warning = try #require(dryRun.warnings.first)
        #expect(warning.code == .audioUnitMissing)
        #expect(warning.message.contains("aumu/tpl8/none"), "the store names it the same way: \(warning.message)")
        #expect(picker.state?.button(.addToSong)?.isEnabled == true, "a missing plug-in warns; it never refuses")
    }

    // MARK: - Save as Template, and the library (Pro)

    @Test("m39-tpl-8: Save as Template writes through template.save's call, makes NO undo step, and comes back on My Templates; a store refusal shows verbatim")
    func tpl8SaveAsTemplate() throws {
        let library = Self.tpl8Library()
        let keys = Track(name: "Keys", kind: .instrument)
        let store = ProjectStore(tracks: [keys, Track(name: "Other", kind: .audio)])
        let picker = TemplatePickerModel(store: store, library: library)
        picker.open(isPro: true)
        picker.openSaveSheet(checking: [keys.id], fromPicker: true)
        #expect(picker.saveSheet?.chosenTrackIDs == [keys.id])
        #expect(picker.saveSheet?.disabledReason == "Give the template a name.")
        #expect(!picker.save(), "Save is off without a name")

        let longName = String(repeating: "x", count: 41)
        let words = try #require(Self.tpl8StoreWords {
            _ = try ProjectStore(tracks: [keys]).saveTemplate(name: longName, trackIDs: [keys.id],
                                                              library: Self.tpl8Library())
        }, "POSITIVE CONTROL: the store refuses a 41-character name")
        picker.setSaveName(longName)
        #expect(!picker.save())
        #expect(picker.saveSheet?.refusal == words)

        picker.setSaveName("My Keys")
        #expect(picker.save())
        #expect(picker.saveSheet == nil)
        let state = try #require(picker.state, "opened from the picker, it comes back to the picker")
        #expect(state.visibleTab == .saved)
        #expect(state.selectedEntry?.name == "My Keys")
        #expect(library.list().templates.contains { $0.source == .saved && $0.name == "My Keys" })
        #expect(!store.canUndo, "saving a template is a file operation: no undo step")
    }

    @Test("m39-tpl-8: Remove asks first, then removes through template.remove's call; Export writes a file the library can import back")
    func tpl8RemoveAndExport() throws {
        let library = Self.tpl8Library()
        let plain = TrackSetTemplate(id: "user-tpl8-rm", name: "Goner", songForm: "pop", tracks: [
            TemplateTrack(key: "keys", name: "Keys", kind: .instrument, instrument: InstrumentDescriptor(
                kind: .soundBank, soundBank: SoundBankConfig(source: .generalMIDI, program: 0))),
        ])
        try Self.tpl8Write(plain, into: library)
        let picker = TemplatePickerModel(store: ProjectStore(), library: library)
        picker.open(preselecting: plain.id, isPro: true)
        picker.setTab(.saved)
        picker.select(plain.id)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl8-export-\(UUID().uuidString).dawtemplate")
        picker.exportSelected(toPath: out.path)
        #expect(picker.state?.libraryLine?.tone == .info, "\(String(describing: picker.state?.libraryLine))")
        #expect(FileManager.default.fileExists(atPath: out.path))

        picker.requestRemoveSelected()
        #expect(picker.state?.pendingRemovalID == plain.id)
        #expect(library.list().entry(id: plain.id) != nil, "nothing is removed before the confirm")
        picker.confirmRemove()
        #expect(library.list().entry(id: plain.id) == nil)
        #expect(picker.state?.libraryLine == .init(tone: .info, text: "Removed \"Goner\"."))

        picker.importTemplate(fromPath: out.path)
        #expect(picker.state?.selectedEntry?.name == "Goner", "the imported template is selected")

        picker.importTemplate(fromPath: "relative/path.dawtemplate")
        let words = try #require(Self.tpl8StoreWords {
            _ = try library.importTemplate(from: "relative/path.dawtemplate")
        }, "POSITIVE CONTROL: the library refuses a relative path")
        #expect(picker.state?.libraryLine == .init(tone: .caution, text: words))
    }
}
