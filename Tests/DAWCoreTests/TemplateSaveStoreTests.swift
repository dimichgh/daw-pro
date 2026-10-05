import Foundation
import Testing
@testable import DAWCore

// m39-tpl-5 — `ProjectStore.saveTemplate` and the store's file verbs
// (docs/design/2026-09-27-multi-instrument-templates.md §5.7, §6.1, §7.2, §8.3).
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite `SongSkeletonTests`, not a new
// suite: the `MainActorOccupancySiteTests` cap on `@MainActor` suites (393 of 394
// used). Helpers carry a `tpl5` prefix. Every library root is a fresh temp folder.
//
// "Changes nothing" is asserted on BYTES: the project document (`tpl2Bytes`), the
// undo depth, `canUndo`, and every file under the library root.

extension SongSkeletonTests {
    // MARK: - Helpers

    func tpl5Library() -> TemplateLibrary {
        TemplateLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true))
    }

    func tpl5LibraryFiles(_ library: TemplateLibrary) -> [String: Data] {
        TemplateLibraryTests().tpl5Files(library.root)
    }

    /// A store holding the Lo-Fi Chill band (keys: drums, bass, keys, vinyl,
    /// duck, room) and one track of its own.
    func tpl5BandStore() throws -> (store: ProjectStore, ids: [String: UUID]) {
        let store = ProjectStore()
        store.media = FakeMedia()
        _ = store.addTrack(name: "Mine", kind: .audio)
        let lofi = try #require(BuiltInTemplateCatalog.load().templates.first { $0.id == "lofi-chill" })
        let result = try store.applyTemplate(lofi.template)
        return (store, result.keyToTrackID)
    }

    /// The project bytes, the undo depth and `canUndo` — what a file verb must not change.
    func tpl5SongState(_ store: ProjectStore) throws -> [String] {
        [try tpl2Bytes(store).base64EncodedString(), "\(store.journal.undoStack.count)",
         "\(store.canUndo)"]
    }

    // MARK: - Save

    @Test("m39-tpl-5: save writes ONE user- file whose bytes are the canonical form, and changes nothing in the song")
    func tpl5SaveWritesOneFile() throws {
        let (store, ids) = try tpl5BandStore()
        let library = tpl5Library()
        let before = try tpl5SongState(store)
        let chosen = ["drums", "bass", "keys", "vinyl", "duck", "room"].compactMap { ids[$0] }
        #expect(chosen.count == 6)
        let result = try store.saveTemplate(name: "My Lo-Fi", trackIDs: chosen,
                                            summary: "Mine, from the lo-fi band.",
                                            songForm: "lo-fi", genres: ["lo-fi"], library: library)
        #expect(result.id.hasPrefix("user-"))
        #expect(result.id.count == 41)
        #expect(result.fileName == "\(result.id).dawtemplate")
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let files = tpl5LibraryFiles(library)
        #expect(Array(files.keys) == [result.fileName])
        #expect(files[result.fileName] == (try TemplateCapture.canonicalJSON(result.template)))
        #expect(result.template.summary == "Mine, from the lo-fi band.")
        let entry = try #require(library.list().entry(id: result.id))
        #expect(entry.source == .saved)
        #expect(entry.template == result.template)
        // No undo entry; the song is byte-identical.
        #expect(try tpl5SongState(store) == before)
    }

    @Test("m39-tpl-5: a saved file applies as the SAME band, by every reading (a real saved template, §8.3)")
    func tpl5SavedFileAppliesAsTheSameBand() throws {
        let (store, ids) = try tpl5BandStore()
        let library = tpl5Library()
        let keys = ["drums", "bass", "keys", "vinyl", "duck", "room"]
        let original = keys.compactMap { key in store.tracks.first { $0.id == ids[key] } }
        let result = try store.saveTemplate(name: "Round Trip", trackIDs: original.map(\.id),
                                            library: library)
        let fresh = ProjectStore()
        fresh.media = FakeMedia()
        let listed = try #require(library.list().entry(id: result.id)).template
        _ = try fresh.applyTemplate(listed)
        #expect(TPL5BandReading(fresh.tracks) == TPL5BandReading(original),
                "\(TPL5BandReading(fresh.tracks).firstDifference(from: TPL5BandReading(original)))")
    }

    @Test("m39-tpl-5: saving one track brings its buses and drops a key from a track you didn't choose")
    func tpl5SaveBringsBusesDropsKeys() throws {
        let (store, ids) = try tpl5BandStore()
        let result = try store.saveTemplate(name: "Just Keys", trackIDs: [try #require(ids["keys"])],
                                            library: tpl5Library())
        #expect(result.template.tracks.map(\.name) == ["Keys", "Keys Duck", "Tape Room"])
        #expect(result.warnings.map(\.code) == [.busIncluded, .busIncluded, .sidechainDropped])
        #expect(result.warnings.last?.message
            == "The Keys Duck compressor listened to Drums, which you didn't save, so it will not duck.")
    }

    @Test("m39-tpl-5: replaceId overwrites that saved file in place; without it nothing is ever overwritten")
    func tpl5ReplaceInPlace() throws {
        let (store, ids) = try tpl5BandStore()
        let library = tpl5Library()
        let first = try store.saveTemplate(name: "Drums Only", trackIDs: [try #require(ids["drums"])],
                                           library: library)
        let second = try store.saveTemplate(name: "Drums Only", trackIDs: [try #require(ids["drums"])],
                                            library: library)
        #expect(first.id != second.id)
        #expect(tpl5LibraryFiles(library).count == 2)
        let replaced = try store.saveTemplate(name: "Bass Now", trackIDs: [try #require(ids["bass"])],
                                              replaceID: first.id, library: library)
        #expect(replaced.id == first.id)
        #expect(replaced.fileName == first.fileName)
        let files = tpl5LibraryFiles(library)
        #expect(files.count == 2)
        #expect(try TrackSetTemplateCodec.decode(try #require(files[first.fileName]), origin: .file)
            .template.name == "Bass Now")
        // A hand-copied file keeps its own file name when replaced.
        var hand = try TemplateCapture.canonical(replaced.template)
        hand.id = "hand-made"
        try TemplateCapture.canonicalJSON(hand).write(
            to: library.root.appendingPathComponent("zz-by-hand.dawtemplate"))
        let byHand = try store.saveTemplate(name: "By Hand", trackIDs: [try #require(ids["keys"])],
                                            replaceID: "hand-made", library: library)
        #expect(byHand.fileName == "zz-by-hand.dawtemplate")
        #expect(tpl5LibraryFiles(library).count == 3)
    }

    @Test("m39-tpl-5: every save refusal leaves every file, the song bytes, the undo depth and canUndo untouched")
    func tpl5SaveRefusalsChangeNothing() throws {
        let (store, ids) = try tpl5BandStore()
        let library = tpl5Library()
        let saved = try store.saveTemplate(name: "Keep Me", trackIDs: [try #require(ids["bass"])],
                                           library: library)
        for _ in 0..<25 { _ = store.addTrack(name: "Crowd", kind: .audio) }
        let crowd = store.tracks.filter { $0.name == "Crowd" }.map(\.id)
        let drums = try #require(ids["drums"])
        // An Audio Unit whose CURRENT sound is 1.6 MB: base64 makes it ~2.13 MB, over the
        // 2 MB bound. A fixture, not a real unit: the largest Apple state measured was the
        // AUSampler holding the GM drum kit, 65,652 B as base64.
        let heavy = store.addTrack(name: "Heavy Plug", kind: .instrument)
        try store.setInstrument(id: heavy.id, audioUnit: AudioUnitConfig(
            component: AudioUnitComponentID(subType: "dls ", manufacturer: "appl"),
            stateData: Data([1])))
        store.instrumentStateProvider = { id in id == heavy.id ? Data(count: 1_600_000) : nil }
        let cases: [(String, () throws -> Void)] = [
            ("replace a built-in", { _ = try store.saveTemplate(name: "X", trackIDs: [drums],
                                                                replaceID: "lofi-chill", library: library) }),
            ("replace an unknown id", { _ = try store.saveTemplate(name: "X", trackIDs: [drums],
                                                                   replaceID: "user-nope", library: library) }),
            ("no tracks", { _ = try store.saveTemplate(name: "X", trackIDs: [], library: library) }),
            ("a stranger's id", { _ = try store.saveTemplate(name: "X", trackIDs: [UUID()], library: library) }),
            ("a 41-character name", { _ = try store.saveTemplate(
                name: String(repeating: "n", count: 41), trackIDs: [drums], library: library) }),
            ("25 tracks", { _ = try store.saveTemplate(name: "X", trackIDs: crowd, library: library) }),
            ("over 2 MB", { _ = try store.saveTemplate(name: "X", trackIDs: [heavy.id], library: library) }),
        ]
        let files = tpl5LibraryFiles(library)
        let song = try tpl5SongState(store)
        for (label, body) in cases {
            #expect(tpl2Refusal(body) != nil, "\(label) was not refused")
            #expect(tpl5LibraryFiles(library) == files, "\(label) changed a file")
            #expect(try tpl5SongState(store) == song, "\(label) changed the song")
        }
        #expect(tpl2Refusal { _ = try store.saveTemplate(name: "X", trackIDs: [drums],
                                                         replaceID: "lofi-chill", library: library) }
            .flatMap { ($0 as? LocalizedError)?.errorDescription }
            == "'lofi-chill' is a built-in template, and built-in templates can't be changed. Save "
                + "without replacing to keep your own copy.")
        let tooBig = tpl2Refusal { _ = try store.saveTemplate(name: "X", trackIDs: [heavy.id],
                                                             library: library) } as? TemplateRefusal
        #expect(tooBig?.code == .tooLarge)
        // SAVE's own sentence, not the codec's backstop ("This template file is …"), which
        // would refuse the same bytes one step later with words about a file.
        #expect(tooBig?.message.hasPrefix("These tracks make a template of ") == true,
                "\(String(describing: tooBig))")
        #expect(tooBig?.message.contains(
            "at most \(TrackSetTemplateCodec.maxFileBytes) bytes (2 MB)") == true)
        #expect(library.list().entry(id: saved.id) != nil)
    }

    @Test("m39-tpl-5: an Audio Unit's CURRENT sound is what gets saved, not the stale one in the model")
    func tpl5SavesTheLiveAudioUnitSound() throws {
        let store = ProjectStore()
        let stale = Data([1, 1, 1])
        let live = Data([9, 9, 9, 9])
        let track = store.addTrack(name: "Plug", kind: .instrument)
        try store.setInstrument(id: track.id, audioUnit: AudioUnitConfig(
            component: AudioUnitComponentID(subType: "dls ", manufacturer: "appl"),
            stateData: stale))
        store.instrumentStateProvider = { _ in live }
        let result = try store.saveTemplate(name: "Plug", trackIDs: [track.id], library: tpl5Library())
        #expect(result.template.tracks[0].instrument?.audioUnit?.stateData == live)
        #expect(store.tracks[0].instrument?.audioUnit?.stateData == stale, "the song is not changed")
    }

    // MARK: - Sound-bank files and Sampler libraries

    @Test("m39-tpl-5: a saved template holding a sound-bank FILE applies while the file exists, and names it when it doesn't")
    func tpl5SoundBankFileTemplate() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5-bank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let bank = scratch.appendingPathComponent("My Bank.sf2")
        try Data("RIFF-not-really".utf8).write(to: bank)
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(name: "Bank Keys", kind: .instrument)
        try store.setInstrument(id: track.id, soundBank: SoundBankConfig(
            source: .file(path: bank.path), program: 5, displayName: "Whatever"))
        let library = tpl5Library()
        let result = try store.saveTemplate(name: "Bank", trackIDs: [track.id], library: library)
        let listed = try #require(library.list().entry(id: result.id)).template
        #expect(listed.tracks[0].instrument?.soundBank?.source == .file(path: bank.path))
        #expect(listed.tracks[0].instrument?.soundBank?.displayName == "My Bank · P5")
        let fresh = ProjectStore()
        _ = try fresh.applyTemplate(listed)
        #expect(TPL5BandReading(fresh.tracks) == TPL5BandReading(store.tracks))
        try FileManager.default.removeItem(at: bank)
        let missing = tpl2Refusal { _ = try ProjectStore().applyTemplate(listed) }
        #expect((missing as? TemplateRefusal)?.message.contains(bank.path) == true, "\(String(describing: missing))")
    }

    /// A short mono 16-bit PCM WAV, a sine at `hertz`: GENERATED here (m39-tpl-5b),
    /// never a copy of the user's recordings, `~/Music` or a system sound.
    func tpl5bWAV(_ url: URL, hertz: Double, seconds: Double = 0.1, rate: Int = 44_100) throws {
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let level = sin(2 * Double.pi * hertz * Double(frame) / Double(rate)) * 0.5 * 32_767
            withUnsafeBytes(of: Int16(level.rounded()).littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: url)
    }

    /// A three-zone `.sfz` library (two velocity layers on the low keys, one zone
    /// on the high keys) whose samples are WAVs generated in a fresh temp folder
    /// (m39-tpl-5b: it copied two system sounds before), imported the way a user
    /// imports one.
    func tpl5SamplerStore() throws -> (store: ProjectStore, track: UUID) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5-sfz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, hertz) in [("low-soft", 110.0), ("low-hard", 110.0), ("high", 440.0)] {
            try tpl5bWAV(folder.appendingPathComponent("\(name).wav"), hertz: hertz)
        }
        let sfz = folder.appendingPathComponent("Three Zones.sfz")
        try Data(("<region> sample=low-soft.wav lokey=28 hikey=52 pitch_keycenter=40 lovel=0 hivel=90 "
            + "pan=-30 tune=12\n"
            + "<region> sample=low-hard.wav lokey=28 hikey=52 pitch_keycenter=40 lovel=91 hivel=127 "
            + "volume=-3\n"
            + "<region> sample=high.wav lokey=53 hikey=90 pitch_keycenter=60 ampeg_release=0.4\n")
            .utf8).write(to: sfz)
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(name: "Kit", kind: .instrument)
        _ = try store.importSampleLibrary(trackID: track.id, path: sfz.path)
        return (store, track.id)
    }

    @Test("m39-tpl-5: a multi-zone Sampler library survives capture → apply in memory, by all readings")
    func tpl5SamplerLibraryRoundTripsInMemory() throws {
        let (store, trackID) = try tpl5SamplerStore()
        let source = try #require(store.tracks.first { $0.id == trackID })
        #expect(source.instrument?.sampler?.zones.count == 3)
        #expect(source.instrument?.sampler?.sourcePath != nil)
        let captured = try TemplateCapture.capture(tracks: store.tracks, selected: [trackID], name: "Kit")
        let failure = try TemplateCaptureTests().tpl5RoundTripFailure(captured.template)
        #expect(failure == nil, "\(failure ?? "")")
        let fresh = ProjectStore()
        fresh.media = FakeMedia()
        _ = try fresh.applyTemplate(captured.template)
        #expect(TPL5BandReading(fresh.tracks) == TPL5BandReading([source]))
    }

    @Test("m39-tpl-5b: a saved template with a multi-zone Sampler AND a sound-bank file: save → file → import → apply on a fresh store plays the same files; a missing file refuses, named, changing nothing")
    func tpl5bSamplerLibraryAndBankFileTravel() throws {
        let (store, kitID) = try tpl5SamplerStore()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5b-bank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // `validateSoundBank` checks the file is there with an .sf2/.dls name; it
        // never parses it (READ: ProjectStore.validateSoundBank).
        let bank = scratch.appendingPathComponent("String Bank.sf2")
        try Data("RIFF-not-really".utf8).write(to: bank)
        let keys = store.addTrack(name: "Bank Strings", kind: .instrument)
        try store.setInstrument(id: keys.id, soundBank: SoundBankConfig(
            source: .file(path: bank.path), program: 48, displayName: "Whatever"))
        let source = store.tracks.filter { $0.id == kitID || $0.id == keys.id }
        let sourceZones = try #require(source.first?.instrument?.sampler?.zones)
        #expect(sourceZones.count == 3)

        // Save: one file in library A, every zone file by absolute path.
        let libraryA = tpl5Library()
        let song = try tpl5SongState(store)
        let saved = try store.saveTemplate(name: "Kit and Strings", trackIDs: [kitID, keys.id],
                                           library: libraryA)
        #expect(saved.warnings.isEmpty, "\(saved.warnings)")
        #expect(try tpl5SongState(store) == song, "saving changes nothing in the song")
        let file = libraryA.root.appendingPathComponent(saved.fileName)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for zone in sourceZones {
            #expect(text.contains("\"path\": \"\(zone.audioFileURL.path)\""), "\(zone.audioFileURL.path)")
            #expect(!text.contains(zone.id.uuidString), "a zone id was written")
        }
        #expect(text.contains("\"source\": \"\(bank.path)\""))

        // Import the file into a second library, then apply on a fresh store.
        let libraryB = tpl5Library()
        let imported = try libraryB.importTemplate(from: file.path)
        #expect(imported.id == saved.id && imported.warnings.isEmpty)
        let entry = try #require(libraryB.list().entry(id: imported.id))
        let fresh = ProjectStore()
        fresh.media = FakeMedia()
        let applied = try fresh.applyTemplate(entry.template)
        #expect(applied.applied && fresh.tracks.count == 2)
        #expect(TPL5BandReading(fresh.tracks) == TPL5BandReading(source))
        let appliedZones = try #require(fresh.tracks.first?.instrument?.sampler?.zones)
        #expect(appliedZones.map { $0.sourceFileKey } == sourceZones.map { $0.sourceFileKey },
                "the applied zones play the same files, in the same order")
        #expect(Set(appliedZones.map { $0.id }).isDisjoint(with: Set(sourceZones.map { $0.id })))
        #expect(!appliedZones.contains { TemplateReader.isSamplerZonePlaceholder($0.id) })
        #expect(fresh.tracks.last?.instrument?.soundBank?.source == .file(path: bank.path))

        // A missing ZONE file: refused before the edit, the file named, nothing changed.
        let gone = sourceZones[1].audioFileURL
        let goneBytes = try Data(contentsOf: gone)
        try FileManager.default.removeItem(at: gone)
        let other = ProjectStore()
        other.media = FakeMedia()
        _ = other.addTrack(name: "Mine", kind: .audio)
        let otherBefore = try tpl5SongState(other)
        for dryRun in [true, false] {
            let refusal = tpl2Refusal { _ = try other.applyTemplate(entry.template, dryRun: dryRun) }
            #expect((refusal as? TemplateRefusal)?.path == "tracks[0].instrument.sampler")
            #expect((refusal as? TemplateRefusal)?.message.contains(gone.path) == true,
                    "\(String(describing: refusal))")
            #expect(try tpl5SongState(other) == otherBefore)
        }
        // …and a missing BANK file, the same way.
        try goneBytes.write(to: gone)
        try FileManager.default.removeItem(at: bank)
        let noBank = tpl2Refusal { _ = try other.applyTemplate(entry.template) }
        #expect((noBank as? TemplateRefusal)?.path == "tracks[1].instrument.soundBank")
        #expect((noBank as? TemplateRefusal)?.message.contains(bank.path) == true,
                "\(String(describing: noBank))")
        #expect(try tpl5SongState(other) == otherBefore)
    }

    @Test("m39-tpl-5b: a Sampler added beside the track it was captured from (twice) gets NEW zone ids every time")
    func tpl5bSamplerZoneIDsAreNew() throws {
        let (store, trackID) = try tpl5SamplerStore()
        let captured = try TemplateCapture.capture(tracks: store.tracks, selected: [trackID], name: "Kit")
        let first = try store.applyTemplate(captured.template)
        let second = try store.applyTemplate(captured.template)
        func zoneIDs(_ id: UUID?) -> [UUID] {
            store.tracks.first { $0.id == id }?.instrument?.sampler?.zones.map { $0.id } ?? []
        }
        let source = zoneIDs(trackID)
        let copyA = zoneIDs(first.tracks.first?.id)
        let copyB = zoneIDs(second.tracks.first?.id)
        #expect(source.count == 3 && copyA.count == 3 && copyB.count == 3)
        // `ProjectDocument` keys each zone's sample file by zone id, project-wide:
        // nine zones, nine ids, or one file would stand in for another on save.
        #expect(Set(source + copyA + copyB).count == 9)
        #expect(!(copyA + copyB).contains { TemplateReader.isSamplerZonePlaceholder($0) })
    }

    // MARK: - The file verbs make no undo entry

    @Test("m39-tpl-5: remove, import and export through the store change no song byte and make no undo entry")
    func tpl5FileVerbsMakeNoUndoEntry() throws {
        let (store, ids) = try tpl5BandStore()
        let library = tpl5Library()
        let saved = try store.saveTemplate(name: "Drums", trackIDs: [try #require(ids["drums"])],
                                           library: library)
        let song = try tpl5SongState(store)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5-verbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let out = scratch.appendingPathComponent("drums.dawtemplate")
        _ = try store.exportTemplate(id: saved.id, to: out.path, library: library)
        let imported = try store.importTemplate(from: out.path, library: library)
        #expect(imported.id != saved.id)
        #expect(store.listTemplates(library: library).templates.filter { $0.source == .saved }.count == 2)
        _ = try store.removeTemplate(id: imported.id, library: library)
        #expect(store.listTemplates(library: library).entry(id: imported.id) == nil)
        #expect(try tpl5SongState(store) == song)
    }
}
