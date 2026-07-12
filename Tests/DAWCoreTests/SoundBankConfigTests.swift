import Foundation
import Testing
@testable import DAWCore

/// m10-n-1 sound-bank instrument identity: `SoundBankSource` one-string
/// Codable, `SoundBankConfig` clamping + structural `Address`,
/// `ProjectStore.setInstrument` validation/ambiguity/kind-implication, and
/// the additive-migration story (old projects decode untouched, nil fields
/// stay byte-identical on re-encode).
@MainActor
@Suite("Sound-bank instrument identity (m10-n-1)")
struct SoundBankConfigTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundbank-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a dummy bank file (content is irrelevant — set-time validation
    /// checks existence + extension only; the engine is what loads bytes).
    private func makeBankFile(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("not a real bank".utf8).write(to: url)
        return url
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    // MARK: - SoundBankSource one-string Codable

    // 1.
    @Test("source encodes as ONE string: \"gm\" sentinel or the absolute path")
    func sourceEncodesAsOneString() throws {
        let gm = try String(data: JSONEncoder().encode(SoundBankSource.generalMIDI),
                            encoding: .utf8)
        #expect(gm == "\"gm\"")
        let file = try String(
            data: JSONEncoder().encode(SoundBankSource.file(path: "/tmp/Vintage.sf2")),
            encoding: .utf8)
        #expect(file == "\"\\/tmp\\/Vintage.sf2\"")  // JSONEncoder escapes slashes
    }

    // 2.
    @Test("source decode: \"gm\" → .generalMIDI, leading \"/\" → .file, anything else throws")
    func sourceDecodeRules() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SoundBankSource.self, from: Data("\"gm\"".utf8))
                == .generalMIDI)
        #expect(try decoder.decode(SoundBankSource.self, from: Data("\"/a/b.dls\"".utf8))
                == .file(path: "/a/b.dls"))
        // The forward seam: unknown sentinels are dataCorrupted, not a path.
        #expect(throws: DecodingError.self) {
            try decoder.decode(SoundBankSource.self, from: Data("\"vintage\"".utf8))
        }
    }

    // 3.
    @Test("config round-trips through Codable for both source forms")
    func configRoundTrip() throws {
        for source in [SoundBankSource.generalMIDI, .file(path: "/tmp/V.sf2")] {
            let config = SoundBankConfig(source: source, program: 56, bankMSB: 121,
                                         bankLSB: 3, displayName: "Trumpet — General MIDI")
            let decoded = try JSONDecoder().decode(SoundBankConfig.self,
                                                   from: JSONEncoder().encode(config))
            #expect(decoded == config)
        }
    }

    // 4.
    @Test("init clamps program/bankMSB/bankLSB into 0…127")
    func initClamps() {
        let high = SoundBankConfig(source: .generalMIDI, program: 200, bankMSB: 300, bankLSB: 128)
        #expect(high.program == 127)
        #expect(high.bankMSB == 127)
        #expect(high.bankLSB == 127)
        let low = SoundBankConfig(source: .generalMIDI, program: -5, bankMSB: -1, bankLSB: -99)
        #expect(low.program == 0)
        #expect(low.bankMSB == 0)
        #expect(low.bankLSB == 0)
    }

    // 5.
    @Test("Address is the structural identity: displayName excluded, every other field in")
    func addressExcludesDisplayName() {
        let a = SoundBankConfig(source: .generalMIDI, program: 56, displayName: "Trumpet")
        var b = a
        b.displayName = "Renamed"
        #expect(a.address == b.address)  // cosmetic rename: NOT structural (LAW L8)
        var c = a
        c.program = 57
        #expect(a.address != c.address)
        var d = a
        d.bankMSB = 120
        #expect(a.address != d.address)
        var e = a
        e.source = .file(path: "/tmp/V.sf2")
        #expect(a.address != e.address)
    }

    // MARK: - setInstrument (domain validation, §3.3)

    // 6.
    @Test("providing soundBank implies kind .soundBank when kind is omitted")
    func kindImplication() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let config = SoundBankConfig(source: .generalMIDI, program: 56)
        let resolved = try #require(try store.setInstrument(id: inst.id, soundBank: config))
        #expect(resolved.kind == .soundBank)
        #expect(resolved.soundBank == config)
        #expect(store.tracks[0].instrument == resolved)
    }

    // 7.
    @Test("audioUnit + soundBank in one call throws ambiguousInstrumentSelection, no edit")
    func ambiguityThrows() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let error = projectError {
            _ = try store.setInstrument(
                id: inst.id,
                audioUnit: AudioUnitConfig(component: AudioUnitComponentID(
                    subType: "samp", manufacturer: "appl")),
                soundBank: SoundBankConfig(source: .generalMIDI))
        }
        guard case .ambiguousInstrumentSelection? = error else {
            Issue.record("expected ambiguousInstrumentSelection, got \(String(describing: error))")
            return
        }
        #expect(error?.errorDescription == "provide either audioUnit or soundBank, not both")
        #expect(store.tracks[0].instrument == nil)  // nothing stored, no undo entry
    }

    // 8.
    @Test("set-time validation: missing bank file throws importFailed and stores nothing")
    func missingFileValidation() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let error = projectError {
            _ = try store.setInstrument(
                id: inst.id,
                soundBank: SoundBankConfig(source: .file(path: "/nonexistent/bank.sf2")))
        }
        guard case .importFailed(let reason)? = error else {
            Issue.record("expected importFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "no sound bank file at /nonexistent/bank.sf2")
        #expect(store.tracks[0].instrument == nil)
    }

    // 9.
    @Test("set-time validation: wrong extension throws importFailed; .sf2/.dls accepted case-insensitively")
    func extensionValidation() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)

        let txt = try makeBankFile(named: "notes.txt", in: dir)
        let error = projectError {
            _ = try store.setInstrument(
                id: inst.id, soundBank: SoundBankConfig(source: .file(path: txt.path)))
        }
        guard case .importFailed(let reason)? = error else {
            Issue.record("expected importFailed, got \(String(describing: error))")
            return
        }
        #expect(reason.contains(".sf2 or .dls"))
        #expect(store.tracks[0].instrument == nil)

        // Existing files with the right extensions pass, whatever their case.
        let sf2 = try makeBankFile(named: "Vintage.SF2", in: dir)
        let dls = try makeBankFile(named: "kit.dls", in: dir)
        for url in [sf2, dls] {
            let resolved = try #require(try store.setInstrument(
                id: inst.id, soundBank: SoundBankConfig(source: .file(path: url.path))))
            #expect(resolved.kind == .soundBank)
        }
        // The "gm" sentinel resolves to the system bank — present on every macOS.
        let gm = try #require(try store.setInstrument(
            id: inst.id, soundBank: SoundBankConfig(source: .generalMIDI, program: 0)))
        #expect(gm.soundBank?.source == .generalMIDI)
    }

    // 10.
    @Test("the stored config survives kind switches (the sampler/audioUnit carry rule)")
    func configSurvivesKindSwitch() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let config = SoundBankConfig(source: .generalMIDI, program: 56, displayName: "Trumpet")
        try store.setInstrument(id: inst.id, soundBank: config)

        try store.setInstrument(id: inst.id, kind: .polySynth)
        #expect(store.tracks[0].instrument?.kind == .polySynth)
        #expect(store.tracks[0].instrument?.soundBank == config)  // carried, not dropped

        try store.setInstrument(id: inst.id, kind: .soundBank)
        #expect(store.tracks[0].instrument?.soundBank == config)  // and restorable
    }

    // MARK: - Migration story (§3.2)

    // 11.
    @Test("a pre-soundBank Track payload decodes with soundBank == nil and re-encodes byte-identically")
    func trackByteIdenticalWithoutSoundBank() throws {
        let track = Track(name: "Synth", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .polySynth))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(track)
        #expect(!String(decoding: first, as: UTF8.self).contains("soundBank"))

        let decoded = try JSONDecoder().decode(Track.self, from: first)
        #expect(decoded.instrument?.soundBank == nil)
        let second = try encoder.encode(decoded)
        #expect(first == second)  // the Model.swift byte-identical re-encode rule
    }

    // 12.
    @Test("InstrumentDocument without the soundBank key decodes nil and omits it on re-encode")
    func instrumentDocumentLegacyDecode() throws {
        let json = """
        { "kind": "polySynth",
          "polySynth": { "waveform": "saw", "attack": 0.005, "decay": 0.08,
                         "sustain": 0.7, "release": 0.15, "cutoffHz": 8000,
                         "resonance": 0.1, "gain": 0.8 } }
        """
        let document = try JSONDecoder().decode(InstrumentDocument.self, from: Data(json.utf8))
        #expect(document.soundBank == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = try String(decoding: encoder.encode(document), as: UTF8.self)
        #expect(!reencoded.contains("soundBank"))
    }

    // 13.
    @Test("an old project file (no soundBank anywhere) opens and re-saves without gaining the key")
    func oldProjectRoundTripsUntouched() throws {
        let dir = tempDir()
        let trackID = UUID().uuidString
        let json = """
        {
          "schemaVersion": 1,
          "name": "Legacy",
          "masterVolume": 1,
          "tracks": [
            { "id": "\(trackID)", "name": "Old Synth", "kind": "instrument", "clips": [],
              "instrument": { "kind": "polySynth",
                              "polySynth": { "waveform": "square", "attack": 0.005,
                                             "decay": 0.08, "sustain": 0.7, "release": 0.15,
                                             "cutoffHz": 8000, "resonance": 0.1, "gain": 0.8 } } }
          ]
        }
        """
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Legacy").path)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"))

        let store = ProjectStore()
        try store.openProject(at: bundleURL.path)
        #expect(store.tracks[0].instrument?.kind == .polySynth)
        #expect(store.tracks[0].instrument?.soundBank == nil)

        let savedPath = dir.appendingPathComponent("Legacy Resaved").path
        try store.saveProject(to: savedPath)
        let savedJSON = try String(contentsOf: ProjectBundle
            .normalizedBundleURL(fromPath: savedPath)
            .appendingPathComponent("project.json"), encoding: .utf8)
        #expect(!savedJSON.contains("soundBank"))  // additive field never materializes
        #expect(savedJSON.contains("polySynth"))
    }

    // 14.
    @Test("a soundBank instrument round-trips through save then open (source persists as \"gm\")")
    func soundBankPersistenceRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let inst = store.addTrack(name: "Horns", kind: .instrument)
        let config = SoundBankConfig(source: .generalMIDI, program: 56, bankMSB: 121,
                                     bankLSB: 0, displayName: "Trumpet — General MIDI")
        try store.setInstrument(id: inst.id, soundBank: config)

        let path = dir.appendingPathComponent("Bank Song").path
        try store.saveProject(to: path)

        // LAW L4: the sentinel — never the /System/… path — is what persists.
        let savedJSON = try String(contentsOf: ProjectBundle
            .normalizedBundleURL(fromPath: path)
            .appendingPathComponent("project.json"), encoding: .utf8)
        #expect(savedJSON.contains("\"source\" : \"gm\"") || savedJSON.contains("\"source\":\"gm\""))
        #expect(!savedJSON.contains("gs_instruments"))

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let horns = try #require(reopened.tracks.first { $0.name == "Horns" })
        #expect(horns.instrument?.kind == .soundBank)
        #expect(horns.instrument?.soundBank == config)
    }

    // MARK: - SoundBankLibrary.resolve

    // 15.
    @Test("resolve: \"gm\" → the system bank; .file → its own path; missing → importFailed")
    func libraryResolve() throws {
        let library = SoundBankLibrary()
        let gm = try library.resolve(.generalMIDI)
        #expect(gm.path == SoundBankLibrary.systemGMBankPath)

        let dir = tempDir()
        let bank = try makeBankFile(named: "V.sf2", in: dir)
        #expect(try library.resolve(.file(path: bank.path)).path == bank.path)

        let error = projectError { _ = try library.resolve(.file(path: "/nope/x.sf2")) }
        guard case .importFailed(let reason)? = error else {
            Issue.record("expected importFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "no sound bank file at /nope/x.sf2")
    }
}
