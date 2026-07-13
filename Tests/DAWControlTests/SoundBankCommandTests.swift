import DAWCore
import DAWEngine
import Foundation
import Testing
@testable import DAWControl

/// m10-n-2 wire surface: `instrument.listSoundBanks`,
/// `instrument.listSoundBankPrograms`, `instrument.importSoundBank`, and the
/// `track.setInstrument` `soundBank` param/response. Injected temp dirs (machine
/// bank dirs are empty, §2.3); the ambiguity path uses a real-AU stand-in so
/// `audioUnit` resolves before the store's mutual-exclusion guard fires.
@MainActor
private final class AUListingEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    func availableAudioUnits() -> [AudioUnitComponentInfo] { AUHostRegistry.listMusicDevices() }
    func availableAudioUnitEffects() -> [AudioUnitComponentInfo] { AUHostRegistry.listEffectComponents() }
}

@MainActor
@Suite("CommandRouter — sound banks (m10-n-2)")
struct SoundBankCommandTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-cmd-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFile(_ name: String, in dir: URL, bytes: String = "bank") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    // MARK: - Minimal SF2 fixture (synthesized — no binary fixtures, §2.3)

    private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func phdrRecord(_ name: String, preset: Int, bank: Int) -> [UInt8] {
        var field = Array(name.utf8.prefix(20)); while field.count < 20 { field.append(0) }
        return field + u16(preset) + u16(bank) + u16(0) + u32(0) + u32(0) + u32(0)
    }
    private func makeSF2(_ presets: [(String, Int, Int)]) -> Data {
        var records: [UInt8] = []
        for p in presets { records += phdrRecord(p.0, preset: p.1, bank: p.2) }
        records += phdrRecord("EOP", preset: 0, bank: 0)
        let phdr = Array("phdr".utf8) + u32(records.count) + records
        let pdta = Array("pdta".utf8) + phdr
        let list = Array("LIST".utf8) + u32(pdta.count) + pdta
        let sfbk = Array("sfbk".utf8) + list
        return Data(Array("RIFF".utf8) + u32(sfbk.count) + sfbk)
    }

    private func makeRouter(library: SoundBankLibrary? = nil,
                            engine: AUListingEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        if let library { store.soundBankLibrary = library }
        if let engine { store.engine = engine }
        return (CommandRouter(store: store), store)
    }

    // MARK: - instrument.listSoundBanks

    // 1.
    @Test("listSoundBanks: GM first (builtin), then scanned banks; full info shape")
    func listSoundBanks() async throws {
        let dir = tempDir()
        try writeFile("Vintage.sf2", in: dir, bytes: String(repeating: "x", count: 100))
        let (router, _) = makeRouter(
            library: SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir]))

        let response = await router.handle(ControlRequest(id: "1", command: "instrument.listSoundBanks"))
        #expect(response.ok)
        let banks = try #require(response.result?["banks"]?.arrayValue)

        let gm = try #require(banks.first { $0["source"]?.stringValue == "gm" })
        #expect(gm["builtin"]?.boolValue == true)
        #expect(gm["format"]?.stringValue == "dls")
        #expect(gm["name"]?.stringValue == "General MIDI")
        #expect(gm["path"]?.stringValue == SoundBankLibrary.systemGMBankPath)
        #expect(banks.first?["source"]?.stringValue == "gm")  // GM is FIRST

        let vintage = try #require(banks.first { $0["name"]?.stringValue == "Vintage" })
        #expect(vintage["format"]?.stringValue == "sf2")
        #expect(vintage["builtin"]?.boolValue == false)
        #expect(vintage["sizeBytes"]?.doubleValue == 100)
        #expect(vintage["source"]?.stringValue?.hasSuffix("Vintage.sf2") == true)
    }

    // MARK: - instrument.listSoundBankPrograms

    // 2.
    @Test("listSoundBankPrograms gm: 0-based spot checks, categories, drum kit, namesParsed:true")
    func listGMPrograms() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listSoundBankPrograms",
            params: ["source": .string("gm")]))
        #expect(response.ok)
        #expect(response.result?["source"]?.stringValue == "gm")
        #expect(response.result?["namesParsed"]?.boolValue == true)
        let programs = try #require(response.result?["programs"]?.arrayValue)
        #expect(programs.count == 129)

        let piano = try #require(programs.first { $0["program"]?.doubleValue == 0
            && $0["bankMSB"]?.doubleValue == 121 })
        #expect(piano["name"]?.stringValue == "Acoustic Grand Piano")  // 0-based (R1)
        #expect(piano["category"]?.stringValue == "Piano")

        let trumpet = try #require(programs.first { $0["program"]?.doubleValue == 56
            && $0["bankMSB"]?.doubleValue == 121 })
        #expect(trumpet["name"]?.stringValue == "Trumpet")
        #expect(trumpet["category"]?.stringValue == "Brass")

        let drum = try #require(programs.last)
        #expect(drum["name"]?.stringValue == "Standard Drum Kit")
        #expect(drum["bankMSB"]?.doubleValue == 120)
        #expect(drum["category"]?.stringValue == "Drum Kits")
    }

    // 3.
    @Test("listSoundBankPrograms for a real .sf2 returns parsed names, namesParsed:true")
    func listSF2Programs() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("Rhodes.sf2")
        try makeSF2([("EP Rhodes", 4, 0), ("Kit", 0, 128)]).write(to: url)
        let (router, _) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listSoundBankPrograms",
            params: ["source": .string(url.path)]))
        #expect(response.ok)
        #expect(response.result?["namesParsed"]?.boolValue == true)
        let programs = try #require(response.result?["programs"]?.arrayValue)
        #expect(programs.count == 2)
        #expect(programs[0]["name"]?.stringValue == "EP Rhodes")
        #expect(programs[0]["program"]?.doubleValue == 4)
        #expect(programs[1]["bankMSB"]?.doubleValue == 120)  // wBank 128 → percussion
    }

    // 4.
    @Test("listSoundBankPrograms: a non-gm, non-path source errors, naming instrument.listSoundBanks")
    func listProgramsBadSource() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listSoundBankPrograms",
            params: ["source": .string("vintage")]))
        #expect(!response.ok)
        #expect(response.error?.contains("instrument.listSoundBanks") == true)
    }

    // 5.
    @Test("listSoundBankPrograms: a missing file errors, naming instrument.listSoundBanks")
    func listProgramsMissingFile() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.listSoundBankPrograms",
            params: ["source": .string("/nonexistent/Ghost.sf2")]))
        #expect(!response.ok)
        #expect(response.error == "no sound bank file at /nonexistent/Ghost.sf2 — see instrument.listSoundBanks")
    }

    // MARK: - track.setInstrument soundBank

    // 6.
    @Test("setInstrument soundBank gm: implies kind, derives displayName, echoes the resolved object")
    func setInstrumentGM() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string("gm"), "program": .number(56)])]))
        #expect(response.ok)
        #expect(response.result?["kind"]?.stringValue == "soundBank")
        let sb = try #require(response.result?["soundBank"])
        #expect(sb["source"]?.stringValue == "gm")
        #expect(sb["path"]?.stringValue == SoundBankLibrary.systemGMBankPath)
        #expect(sb["program"]?.doubleValue == 56)
        #expect(sb["bankMSB"]?.doubleValue == 121)  // melodic default
        #expect(sb["bankLSB"]?.doubleValue == 0)
        #expect(sb["name"]?.stringValue == "Trumpet — General MIDI")  // server-derived
        #expect(sb["status"]?.stringValue == "pending")  // headless default

        // Model landed the config with source "gm" persisted (never the path).
        let stored = try #require(store.tracks[0].instrument?.soundBank)
        #expect(stored.source == .generalMIDI)
        #expect(stored.program == 56)
        #expect(stored.displayName == "Trumpet — General MIDI")
    }

    // 7.
    @Test("setInstrument soundBank for an .sf2 file derives the parsed preset name")
    func setInstrumentSF2() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("Rhodes.sf2")
        try makeSF2([("EP Rhodes", 4, 0)]).write(to: url)
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string(url.path),
                                           "program": .number(4),
                                           "bankMSB": .number(121)])]))
        #expect(response.ok)
        let sb = try #require(response.result?["soundBank"])
        #expect(sb["source"]?.stringValue == url.path)
        #expect(sb["path"]?.stringValue == url.path)
        #expect(sb["name"]?.stringValue == "EP Rhodes — Rhodes")  // "<preset> — <stem>"
    }

    // 8.
    @Test("setInstrument soundBank + audioUnit in one call errors readably (ambiguity), nothing lands")
    func setInstrumentAmbiguity() async throws {
        let engine = AUListingEngine()
        let (router, store) = makeRouter(engine: engine)
        _ = engine  // strong hold: store.engine is weak
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     // AUSampler ('samp'/'appl') resolves on this machine (§2.3),
                     // so the store's mutual-exclusion guard is what fires.
                     "audioUnit": .object(["subType": .string("samp"),
                                           "manufacturer": .string("appl")]),
                     "soundBank": .object(["source": .string("gm")])]))
        #expect(!response.ok)
        #expect(response.error == "provide either audioUnit or soundBank, not both")
        #expect(store.tracks[0].instrument == nil)  // nothing landed
    }

    // 9.
    @Test("setInstrument soundBank: a missing file errors, naming instrument.listSoundBanks; nothing lands")
    func setInstrumentMissingFile() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string("/nope/x.sf2")])]))
        #expect(!response.ok)
        #expect(response.error == "no sound bank file at /nope/x.sf2 — see instrument.listSoundBanks")
        #expect(store.tracks[0].instrument == nil)
    }

    // 10.
    @Test("setInstrument soundBank: a wrong-extension file errors, naming instrument.listSoundBanks")
    func setInstrumentBadExtension() async throws {
        let dir = tempDir()
        let txt = try writeFile("notes.txt", in: dir)
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string(txt.path)])]))
        #expect(!response.ok)
        #expect(response.error?.contains(".sf2 or .dls") == true)
        #expect(response.error?.contains("instrument.listSoundBanks") == true)
        #expect(store.tracks[0].instrument == nil)
    }

    // 11.
    @Test("project.snapshot carries the resolved soundBank object")
    func snapshotCarriesSoundBank() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(name: "Horns", kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string("gm"), "program": .number(56)])]))

        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        #expect(snapshot.ok)
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let horns = try #require(tracks.first { $0["name"]?.stringValue == "Horns" })
        let sb = try #require(horns["instrument"]?["soundBank"])
        #expect(sb["source"]?.stringValue == "gm")
        #expect(sb["name"]?.stringValue == "Trumpet — General MIDI")
        #expect(sb["status"]?.stringValue == "pending")
    }

    // MARK: - instrument.importSoundBank

    // 12.
    @Test("importSoundBank copies into the library, returns bank info, leaves the source in place")
    func importHappy() async throws {
        let libraryDir = tempDir()
        let sourceDir = tempDir()
        let source = try writeFile("Strings.sf2", in: sourceDir, bytes: String(repeating: "x", count: 64))
        let (router, _) = makeRouter(
            library: SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir]))

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.importSoundBank",
            params: ["path": .string(source.path)]))
        #expect(response.ok)
        let bank = try #require(response.result?["bank"])
        #expect(bank["name"]?.stringValue == "Strings")
        #expect(bank["format"]?.stringValue == "sf2")
        #expect(bank["builtin"]?.boolValue == false)
        #expect(bank["sizeBytes"]?.doubleValue == 64)
        let landedPath = try #require(bank["path"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: landedPath))
        #expect(FileManager.default.fileExists(atPath: source.path))  // copy, not move
    }

    // 13.
    @Test("importSoundBank uniquifies a name collision")
    func importCollision() async throws {
        let libraryDir = tempDir()
        let dirA = tempDir(); let dirB = tempDir()
        let first = try writeFile("Vintage.sf2", in: dirA, bytes: "one")
        let second = try writeFile("Vintage.sf2", in: dirB, bytes: "two-different")
        let (router, _) = makeRouter(
            library: SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir]))

        _ = await router.handle(ControlRequest(id: "1", command: "instrument.importSoundBank",
                                               params: ["path": .string(first.path)]))
        let response = await router.handle(ControlRequest(id: "2", command: "instrument.importSoundBank",
                                                          params: ["path": .string(second.path)]))
        #expect(response.ok)
        #expect(response.result?["bank"]?["name"]?.stringValue == "Vintage-2")
    }

    // 14.
    @Test("importSoundBank rejects a wrong extension and a missing file readably")
    func importValidationErrors() async throws {
        let dir = tempDir()
        let txt = try writeFile("readme.txt", in: dir)
        let (router, _) = makeRouter(
            library: SoundBankLibrary(libraryDirectory: tempDir(), scanDirectories: []))

        let badExt = await router.handle(ControlRequest(
            id: "1", command: "instrument.importSoundBank", params: ["path": .string(txt.path)]))
        #expect(!badExt.ok)
        #expect(badExt.error == "Audio import failed: sound bank must be a .sf2 or .dls file — got readme.txt")

        let missing = await router.handle(ControlRequest(
            id: "2", command: "instrument.importSoundBank",
            params: ["path": .string("/nope/Ghost.sf2")]))
        #expect(!missing.ok)
        #expect(missing.error == "Audio import failed: no sound bank file at /nope/Ghost.sf2")
    }

    // 15.
    @Test("importSoundBank rejects a non-absolute path")
    func importRejectsRelativePath() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.importSoundBank",
            params: ["path": .string("relative/bank.sf2")]))
        #expect(!response.ok)
        #expect(response.error == "'path' must be an absolute path")
    }

    // 16.
    @Test("allCommands carries the three instrument.* additions (m10-n-2); count now 118")
    func commandCountPin() {
        // m10-n-2 took the surface 105 → 108 with these three; m11-b's read-only
        // edit.history took it 108 → 109; m11-c's five marker.* commands took it
        // 109 → 114; m11-d's clip.crossfade took it 114 → 115; m11-e's
        // track.bounceInPlace took it 115 → 116; m12-d's tempo.map + tempo.setMap
        // took it 116 → 118; m12-g's fx.setSidechain took it 118 → 119; m13-e's
        // clip.setGainEnvelope took it 119 → 120. m15-d's clip.duplicate +
        // arrange.insertBars + arrange.deleteBars took it 120 → 123. m16-b2's
        // clip.setControllerLane + clip.removeControllerLane took it 123 → 125.
        // The three instrument commands must stay.
        #expect(CommandRouter.allCommands.count == 125)
        #expect(CommandRouter.allCommands.contains("instrument.listSoundBanks"))
        #expect(CommandRouter.allCommands.contains("instrument.listSoundBankPrograms"))
        #expect(CommandRouter.allCommands.contains("instrument.importSoundBank"))
        #expect(CommandRouter.allCommands.contains("clip.crossfade"))
        #expect(CommandRouter.allCommands.contains("track.bounceInPlace"))
        #expect(CommandRouter.allCommands.contains("clip.duplicate"))
        #expect(CommandRouter.allCommands.contains("arrange.insertBars"))
        #expect(CommandRouter.allCommands.contains("arrange.deleteBars"))
        #expect(CommandRouter.allCommands.contains("tempo.map"))
        #expect(CommandRouter.allCommands.contains("tempo.setMap"))
        #expect(CommandRouter.allCommands.contains("fx.setSidechain"))
        #expect(CommandRouter.allCommands.contains("clip.setGainEnvelope"))
    }
}
