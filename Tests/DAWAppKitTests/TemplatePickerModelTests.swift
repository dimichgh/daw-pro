import AppKit
import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// m39-tpl-8 — the template picker's DECISIONS, without a window and without a
/// store (docs/design/2026-09-27-multi-instrument-templates.md §9.2, §9.3).
///
/// Nonisolated on purpose: everything here is `TemplatePickerState`, a pure
/// value, fed the two things the live song supplies AS DATA (`facts`, and the
/// store's dry-run answer as a `preflight`). The store half — that a press makes
/// the SAME call the wire makes, that a refusal reaches the card verbatim, undo —
/// is appended to `SketchpadModelTests` (`TemplatePickerStoreTests.swift`),
/// because it needs the main actor and the suite cap is full.
///
/// ⭐ The §9 sentences are pinned as LITERALS, not read back from
/// `TemplatePickerCopy`: a test that compared the copy with itself would pass a
/// card that says the wrong thing.
@Suite("m39-tpl-8: TemplatePickerState — tiles, buttons, states, words")
struct TemplatePickerModelTests {

    // MARK: - Fixtures

    static let builtIns = BuiltInTemplateCatalog.load()

    static func listing(saved: [TrackSetTemplate] = [],
                        unreadable: [TemplateLibrary.Unreadable] = []) -> TemplateLibrary.Listing {
        let entries = builtIns.templates.map {
            TemplateLibrary.Entry(id: $0.id, name: $0.template.name, source: .builtIn,
                                  fileName: $0.fileName, template: $0.template, warnings: [])
        } + saved.map {
            TemplateLibrary.Entry(id: $0.id, name: $0.name, source: .saved,
                                  fileName: "\($0.id).dawtemplate", template: $0, warnings: [])
        }
        return TemplateLibrary.Listing(templates: entries, unreadable: unreadable)
    }

    static let emptySong = TemplatePickerFacts(songHasTracks: false, isRecording: false, tempoBPM: 120)
    static let busySong = TemplatePickerFacts(songHasTracks: true, isRecording: false, tempoBPM: 120)

    static func state(_ facts: TemplatePickerFacts = emptySong, selected: String? = "pop-band",
                      isPro: Bool = false, saved: [TrackSetTemplate] = [],
                      unreadable: [TemplateLibrary.Unreadable] = [],
                      preflight: TemplatePickerPreflight? = nil) -> TemplatePickerState {
        TemplatePickerState(listing: listing(saved: saved, unreadable: unreadable),
                            selectedID: selected, isPro: isPro, facts: facts, preflight: preflight)
    }

    /// A preflight the store would give a template it accepts, with `hasRouting`.
    static func cleanPreflight(_ id: String, genre: String, hasRouting: Bool,
                               tempo: Double? = nil) -> TemplatePickerPreflight {
        TemplatePickerPreflight(templateID: id, genre: genre, hasRouting: hasRouting, startRefusal: nil,
                                addRefusal: nil, warnings: [], plugIns: [],
                                startTempoBPM: tempo ?? SongSkeletonCatalog.genre(named: genre)?.defaultTempoBPM)
    }

    static func savedTemplate(_ id: String, name: String, songForm: String? = nil,
                              genres: [String] = []) -> TrackSetTemplate {
        TrackSetTemplate(id: id, name: name, songForm: songForm, genres: genres, tracks: [
            TemplateTrack(key: "keys", name: "Keys", kind: .instrument),
        ])
    }

    // MARK: - Tiles (§9.2)

    @Test("Simple shows the ten built-ins in catalog order — name, summary, glyphs, \"N tracks\" — and nothing saved")
    func simpleShowsTheTenBuiltIns() throws {
        #expect(Self.builtIns.unreadable.isEmpty, "POSITIVE CONTROL: the catalog loads in this test process")
        let state = Self.state(saved: [Self.savedTemplate("user-a", name: "Mine")])
        #expect(state.visibleTab == .builtIn)
        #expect(state.tiles.map(\.id) == BuiltInTemplateCatalog.ids)
        #expect(state.tiles.count == 10)
        #expect(!state.tiles.contains { $0.source == .saved }, "Simple must not show saved templates")
        #expect(!state.showsTabs && !state.showsLibraryRow && !state.showsDetail)
        let lofi = try #require(state.tiles.first { $0.id == "lofi-chill" })
        let entry = try #require(Self.builtIns.templates.first { $0.id == "lofi-chill" })
        #expect(lofi.name == "Lo-Fi Chill")
        #expect(lofi.summary == entry.template.summary)
        #expect(lofi.trackCountLabel == "6 tracks")
        // Drums (drum machine), Bass (GM 33), Keys (GM 4), Vinyl FX (audio); the two buses draw no glyph.
        #expect(lofi.glyphs == [.drums, .bass, .keys, .audio])
    }

    @Test("Pro adds the Built-in / My Templates switch; saved tiles by file name; an unreadable file is greyed with its reason, verbatim")
    func proShowsSavedAndUnreadable() {
        let reason = "Another template already uses this id. Import it again to give it a new one."
        var state = Self.state(isPro: true, saved: [Self.savedTemplate("user-a", name: "Mine")],
                               unreadable: [.init(file: "broken.dawtemplate", source: .saved, message: reason)])
        #expect(state.showsTabs && state.showsLibraryRow && state.showsDetail)
        #expect(state.tiles.count == 10, "Pro opens on Built-in")
        #expect(state.unreadableTiles.isEmpty, "the saved file's problem belongs to My Templates")
        state.tab = .saved
        #expect(state.tiles.map(\.id) == ["user-a"])
        #expect(state.unreadableTiles == [.init(file: "broken.dawtemplate", source: .saved, reason: reason)])
        #expect(state.gridCellCount == 2)
        #expect(!state.showsEmptySavedLine)
        // Simple, even with the tab left on My Templates, shows built-ins only.
        state.isPro = false
        #expect(state.visibleTab == .builtIn)
        #expect(state.unreadableTiles.isEmpty)
    }

    @Test("an empty My Templates says so instead of drawing nothing")
    func emptySavedTabSaysSo() {
        var state = Self.state(isPro: true)
        state.tab = .saved
        #expect(state.tiles.isEmpty)
        #expect(state.showsEmptySavedLine)
        #expect(TemplatePickerCopy.noSavedTemplates.hasPrefix("No saved templates yet."))
        #expect(state.defaultSelection(preferring: "pop-band") == nil,
                "a built-in id is not on My Templates")
    }

    // MARK: - Buttons (§9.2, §9.3)

    @Test("an empty song: Start a song is primary (Return), Add to my song secondary, both enabled, with §9.2's captions")
    func emptySongStartsASong() throws {
        let state = Self.state(preflight: Self.cleanPreflight("pop-band", genre: "pop", hasRouting: true))
        #expect(state.primaryAction == .startSong)
        #expect(state.buttons.map(\.action) == [.addToSong, .startSong], "primary sits last, at the trailing edge")
        let start = try #require(state.button(.startSong))
        let add = try #require(state.button(.addToSong))
        #expect(start.isPrimary && !add.isPrimary)
        #expect(start.isEnabled && add.isEnabled)
        #expect(start.title == "Start a song")
        #expect(start.explanation == "Adds this band and a song outline: tempo, sections and a loop.")
        #expect(add.title == "Add to my song")
        #expect(add.explanation == "Adds these tracks. Nothing you already have changes.")
        #expect(state.messages.isEmpty, "an empty song needs no warning: \(state.messages)")
    }

    @Test("a song with tracks: Add to my song is primary, and Start a song says what else it changes BEFORE the press")
    func songWithTracksPrefersAdding() throws {
        let hipHop = TemplatePickerFacts(songHasTracks: true, isRecording: false, tempoBPM: 120)
        let state = Self.state(hipHop, selected: "hip-hop-808",
                               preflight: Self.cleanPreflight("hip-hop-808", genre: "hip-hop", hasRouting: true))
        #expect(state.primaryAction == .addToSong)
        #expect(state.buttons.map(\.action) == [.startSong, .addToSong])
        #expect(try #require(state.button(.startSong)).isEnabled, "Start a song stays available")
        // §9.3, verbatim, at the style's own tempo (hip-hop: 90).
        #expect(state.messages == [.init(tone: .caution, text:
            "This also sets the tempo to 90 BPM and adds song sections and a loop. Your tracks stay. Notes will "
            + "play at the new speed, and recordings may no longer line up with the beat.")])
    }

    @Test("the re-tempo warning drops its tempo half when the song is already at the style's tempo")
    func retempoWarningIsTrueAtTheSameTempo() {
        // Pop is 120 BPM and so is this song: "sets the tempo to 120" would be false.
        let state = Self.state(Self.busySong,
                               preflight: Self.cleanPreflight("pop-band", genre: "pop", hasRouting: true))
        #expect(state.messages == [.init(tone: .caution,
                                         text: "This also adds song sections and a loop. Your tracks stay.")])
    }

    @Test("while recording, a template that connects its tracks has BOTH buttons off with §9.3's sentence; a plain one stays on")
    func recordingDisablesOnlyRoutedTemplates() throws {
        let recording = TemplatePickerFacts(songHasTracks: true, isRecording: true, tempoBPM: 120)
        let routed = Self.state(recording, preflight: Self.cleanPreflight("pop-band", genre: "pop", hasRouting: true))
        for button in routed.buttons {
            #expect(!button.isEnabled, "\(button.action)")
            #expect(button.disabledReason == "Stop recording to add this band.")
        }
        #expect(routed.messages == [.init(tone: .caution, text: "Stop recording to add this band.")],
                "the reason shows once, and no re-tempo line rides beside a button that cannot run")

        let plain = Self.state(recording, preflight: Self.cleanPreflight("pop-band", genre: "pop", hasRouting: false))
        #expect(plain.buttons.allSatisfy { $0.isEnabled }, "a template of plain tracks adds mid-take, like track.add")
    }

    @Test("a dry-run refusal turns its button off and shows the STORE's sentence, verbatim, once")
    func dryRunRefusalIsShownVerbatim() throws {
        let words = "tracks[0].instrument.soundBank: this sound bank can't be used: no file at /nowhere.sf2."
        var preflight = Self.cleanPreflight("pop-band", genre: "pop", hasRouting: false)
        preflight.addRefusal = words
        preflight.startRefusal = words
        let state = Self.state(preflight: preflight)
        #expect(try #require(state.button(.addToSong)).disabledReason == words)
        #expect(try #require(state.button(.startSong)).disabledReason == words)
        #expect(state.messages == [.init(tone: .caution, text: words)])
    }

    @Test("a stale preflight (another template, another style) is never shown against the selection")
    func stalePreflightIsIgnored() {
        var preflight = Self.cleanPreflight("rock-band", genre: "rock", hasRouting: true)
        preflight.addRefusal = "rock's refusal"
        let state = Self.state(preflight: preflight)
        #expect(state.currentPreflight == nil)
        #expect(state.buttons.allSatisfy { $0.isEnabled })
        #expect(state.messages.isEmpty)
    }

    @Test("a press refusal shows first, in the store's words")
    func pressRefusalComesFirst() {
        var state = Self.state(preflight: Self.cleanPreflight("pop-band", genre: "pop", hasRouting: true))
        state.pressRefusal = "cannot add a template whose tracks play into each other while recording — stop first"
        #expect(state.messages.first == .init(tone: .caution, text: state.pressRefusal!))
    }

    // MARK: - Song style (§9.3)

    @Test("a saved template with no song form gets the Song style menu: 14 styles, its first genre, else Pop; a built-in gets none")
    func songStyleMenu() throws {
        let noForm = Self.savedTemplate("user-a", name: "Mine")
        let jazzy = Self.savedTemplate("user-b", name: "Jazzy", genres: ["not-a-style", "jazz"])
        let formed = Self.savedTemplate("user-c", name: "Formed", songForm: "rock")

        var state = Self.state(selected: "user-a", isPro: true, saved: [noForm, jazzy, formed])
        state.tab = .saved
        let menu = try #require(state.songStyleMenu)
        #expect(menu.options.count == 14)
        #expect(menu.options.map(\.genre) == SongSkeletonCatalog.names)
        #expect(menu.selectedGenre == "pop")
        #expect(menu.selectedTitle == "Pop")
        #expect(state.startGenre == "pop")

        state.selectedID = "user-b"
        #expect(state.songStyleMenu?.selectedGenre == "jazz", "its first CATALOG genre")
        state.songStyleChoice = "reggae"
        #expect(state.startGenre == "reggae")
        #expect(state.songStyleMenu?.selectedTitle == "Reggae")

        state.selectedID = "user-c"
        state.songStyleChoice = nil
        #expect(state.songStyleMenu == nil, "a template with a song form needs no menu")
        #expect(state.startGenre == "rock")

        let builtIn = Self.state()
        #expect(builtIn.songStyleMenu == nil)
        #expect(builtIn.startGenre == "pop")
        #expect(TemplatePickerCopy.songStyleLabel == "Song style")
    }

    // MARK: - Plug-ins (§9.3)

    @Test("a template with a plug-in says so before the press; a missing one (the store's dry-run warning) says it isn't installed")
    func plugInNotices() {
        var preflight = Self.cleanPreflight("pop-band", genre: "pop", hasRouting: false)
        preflight.plugIns = [.init(path: "tracks[0].instrument.audioUnit", name: "Ghost Synth"),
                             .init(path: "tracks[1].inserts[0].audioUnit", name: "AUDelay")]
        preflight.warnings = [TemplateWarning(code: .audioUnitMissing, path: "tracks[0].instrument.audioUnit",
                                              message: "the store's own missing-plug-in sentence")]
        let state = Self.state(preflight: preflight)
        #expect(state.messages == [
            .init(tone: .caution, text: "Ghost Synth isn't installed on this Mac. The track will be added without its sound."),
            .init(tone: .info, text: "Uses a plug-in: AUDelay. Plug-ins can take a while to load."),
        ])
    }

    @Test("a plug-in is named by its own name, else this Mac's name for it, else its component code")
    func plugInNaming() {
        let id = AudioUnitComponentID(subType: "abcd", manufacturer: "efgh")
        #expect(TemplatePickerModel.plugInName(AudioUnitConfig(component: id, name: "Mine"),
                                               installedName: "Mac's") == "Mine")
        #expect(TemplatePickerModel.plugInName(AudioUnitConfig(component: id), installedName: "AUDelay") == "AUDelay")
        #expect(TemplatePickerModel.plugInName(AudioUnitConfig(component: id), installedName: nil) == "aumu/abcd/efgh")
    }

    @Test("the store's other dry-run warnings are shown verbatim")
    func otherWarningsVerbatim() {
        var preflight = Self.cleanPreflight("pop-band", genre: "pop", hasRouting: true)
        preflight.warnings = [TemplateWarning(code: .duplicateTrackNames, path: "tracks[0].name",
                                              message: "After this, the song has 2 tracks called 'Drums'.")]
        let state = Self.state(preflight: preflight)
        #expect(state.messages == [.init(tone: .info, text: "After this, the song has 2 tracks called 'Drums'.")])
    }

    // MARK: - Pro detail (§9.2)

    @Test("Pro's detail pane lists each track in plain words — \"Keys: <instrument>. Plays into Keys Duck. Sends to Tape Room.\"")
    func detailLines() throws {
        let simple = Self.state(selected: "lofi-chill")
        #expect(simple.detailLines.isEmpty, "Simple has no detail pane")
        let pro = Self.state(selected: "lofi-chill", isPro: true)
        let lofi = try #require(Self.builtIns.templates.first { $0.id == "lofi-chill" }).template
        let keys = try #require(lofi.tracks.first { $0.key == "keys" })
        let lines = pro.detailLines
        #expect(lines.count == lofi.tracks.count)
        #expect(lines.contains("Keys: \(InstrumentPickerModel.displayName(for: keys.instrument)). Plays into Keys Duck. Sends to Tape Room."))
        #expect(lines.contains("Vinyl FX: an audio track, for recording."))
        #expect(lines.contains("Keys Duck: a shared bus that Keys plays into. It ducks when Drums plays."))
        #expect(lines.contains("Tape Room: a shared bus that Drums and Keys play into."))
    }

    @Test("Remove is offered for a saved template only; Export for any; both Pro only")
    func removeAndExportAvailability() {
        var state = Self.state(isPro: true, saved: [Self.savedTemplate("user-a", name: "Mine")])
        #expect(!state.canRemove && state.canExport)
        state.tab = .saved
        state.selectedID = "user-a"
        #expect(state.canRemove && state.canExport)
        state.isPro = false
        #expect(!state.canRemove && !state.canExport)
    }

    // MARK: - Every other string (§9.1, §9.2)

    @Test("the card's, the menus' and the notice's words are §9's")
    func everyString() {
        #expect(TemplatePickerCopy.title == "Start with a band")
        #expect(TemplatePickerCopy.subtitle == "Pick a sound to start from. You can change every part later.")
        #expect(TemplatePickerCopy.addBandMenuItem == "Add a Band from a Template…")
        #expect(TemplatePickerCopy.saveTrackMenuItem == "Save Track as Template…")
        #expect(TemplatePickerCopy.builtInTab == "Built-in")
        #expect(TemplatePickerCopy.savedTab == "My Templates")
        #expect(TemplatePickerCopy.importButton == "Import…")
        #expect(TemplatePickerCopy.exportButton == "Export…")
        #expect(TemplatePickerCopy.removeButton == "Remove")
        #expect(TemplatePickerCopy.saveAsTemplateButton == "Save as Template…")
        #expect(TemplatePickerCopy.stopRecording == "Stop recording to add this band.")
        #expect(TemplatePickerCopy.addedNotice(name: "Lo-Fi Chill", trackCount: 6)
                == "Added Lo-Fi Chill: 6 tracks. The tracks are empty: add notes, record, or ask the Copilot "
                   + "to write a part. Press ⌘Z to undo.")
        #expect(TemplatePickerCopy.startedNotice(name: "Pop Band", trackCount: 7, tempoBPM: 120)
                == "Added Pop Band: 7 tracks, and a song outline at 120 BPM. The tracks are empty: add notes, "
                   + "record, or ask the Copilot to write a part. Press ⌘Z to undo.")
        #expect(TemplatePickerCopy.usesPlugIn("X") == "Uses a plug-in: X. Plug-ins can take a while to load.")
        #expect(TemplatePickerCopy.plugInMissing("X")
                == "X isn't installed on this Mac. The track will be added without its sound.")
        #expect(TemplatePickerCopy.trackCount(1) == "1 track")
        #expect(TemplatePickerCopy.bpm(92.5) == "92.5")
        #expect(TemplatePickerCopy.bpm(90) == "90")
    }

    // MARK: - Glyphs

    @Test("every glyph names an SF Symbol this Mac draws (an unknown name draws NOTHING, silently)")
    func everyGlyphSymbolExists() {
        #expect(NSImage(systemSymbolName: "definitely.not.a.symbol.tpl8", accessibilityDescription: nil) == nil,
                "POSITIVE CONTROL: an unknown name must read as missing, or this test is blind")
        for glyph in TemplateTrackGlyph.allCases {
            #expect(NSImage(systemSymbolName: glyph.systemImage, accessibilityDescription: nil) != nil,
                    "\(glyph) → \(glyph.systemImage)")
        }
    }

    @Test("glyphs come from the instrument: GM families, the GM kit, the drum machine, the Poly Synth, audio, plug-ins; a bus has none")
    func glyphRules() {
        func gm(_ program: Int, msb: Int = GMProgramCatalog.melodicBankMSB) -> TemplateTrack {
            TemplateTrack(key: "t", name: "T", kind: .instrument, instrument: InstrumentDescriptor(
                kind: .soundBank, soundBank: SoundBankConfig(source: .generalMIDI, program: program, bankMSB: msb)))
        }
        #expect(TemplateTrackGlyph.glyph(for: gm(0)) == .keys)
        #expect(TemplateTrackGlyph.glyph(for: gm(16)) == .keys)
        #expect(TemplateTrackGlyph.glyph(for: gm(25)) == .guitar)
        #expect(TemplateTrackGlyph.glyph(for: gm(33)) == .bass)
        #expect(TemplateTrackGlyph.glyph(for: gm(48)) == .strings)
        #expect(TemplateTrackGlyph.glyph(for: gm(56)) == .winds)
        #expect(TemplateTrackGlyph.glyph(for: gm(89)) == .synth)
        #expect(TemplateTrackGlyph.glyph(for: gm(0, msb: GMProgramCatalog.percussionBankMSB)) == .drums)
        #expect(TemplateTrackGlyph.glyph(for: TemplateTrack(
            key: "d", name: "Drums", kind: .instrument, instrument: InstrumentDescriptor(kind: .drumSynth))) == .drums)
        #expect(TemplateTrackGlyph.glyph(for: TemplateTrack(key: "s", name: "S", kind: .instrument)) == .synth)
        #expect(TemplateTrackGlyph.glyph(for: TemplateTrack(key: "v", name: "Lead Vocal", kind: .audio)) == .voice)
        #expect(TemplateTrackGlyph.glyph(for: TemplateTrack(key: "f", name: "Vinyl FX", kind: .audio)) == .audio)
        #expect(TemplateTrackGlyph.glyph(for: TemplateTrack(key: "b", name: "Room", kind: .bus)) == nil)
    }

    // MARK: - Save as Template (§7.2)

    @Test("Save is off with a reason until there is a name and a ticked track; ticked tracks go in song order")
    func saveSheetState() {
        let a = Track(name: "Drums", kind: .instrument)
        let b = Track(name: "Bass", kind: .instrument)
        let c = Track(name: "Room", kind: .bus)
        var sheet = TemplateSaveSheetState(rows: TemplateSaveSheetState.rows(for: [a, b, c], checked: [c.id, a.id]),
                                           returnsToPicker: false)
        #expect(sheet.rows.map(\.name) == ["Drums", "Bass", "Room"])
        #expect(sheet.chosenTrackIDs == [a.id, c.id], "song order, not tick order")
        #expect(sheet.disabledReason == "Give the template a name.")
        sheet.name = "   "
        #expect(sheet.disabledReason == "Give the template a name.", "blank is not a name")
        sheet.name = "  My Band "
        #expect(sheet.trimmedName == "My Band")
        #expect(sheet.canSave)
        for index in sheet.rows.indices { sheet.rows[index].isChecked = false }
        #expect(sheet.disabledReason == "Choose at least one track.")
        let empty = TemplateSaveSheetState(rows: [], returnsToPicker: false)
        #expect(empty.disabledReason == "This song has no tracks to save yet.")
    }
}
