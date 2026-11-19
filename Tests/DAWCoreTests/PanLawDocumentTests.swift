import Foundation
import Testing
@testable import DAWCore

// m39-panlaw-new (W9-PANLAW) — the song's pan rule in the FILE and in the STORE.
//
// The user's pick (2026-10-07, "One rule for new songs only"): new songs pan their knobs with the automation rule,
// songs already made keep their sound exactly, and the rule costs one setting saved with each song. A byte gate over
// renders cannot see a DECODE default, so the decoded value is asserted here directly: a file with no key reads as
// the original rule, the key is written only for the new rule, and the store pushes whatever it holds to the engine.

@Suite("m39-panlaw-new: the pan rule in the song file")
struct PanLawDocumentTests {
    static func document(panLaw: PanLaw) -> ProjectDocument {
        ProjectDocument(name: "Pan", transport: TransportState(),
                        tracks: [Track(name: "T", kind: .audio, pan: 0.4)],
                        masterVolume: 1, mediaRefs: [:], panLaw: panLaw)
    }

    static func json(_ document: ProjectDocument) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
        return try #require(object as? [String: Any])
    }

    @Test("A song saved without the setting decodes to the ORIGINAL rule (key absent → nil → balance)")
    func absentKeyIsTheOriginalRule() throws {
        let object = try Self.json(Self.document(panLaw: .balance))
        #expect(object["panLaw"] == nil, "control: the original rule writes no key")
        #expect(object["tracks"] != nil, "control: the object is a real song document")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(!String(decoding: data, as: UTF8.self).contains("panLaw"))
        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: data)
        #expect(decoded.panLaw == nil)
        #expect(decoded.runtimePanLaw == .balance)
        #expect(decoded.panLawUnreadOnLoad == nil)
        #expect(decoded.runtimeState(bundleURL: FileManager.default.temporaryDirectory).warnings.isEmpty)
    }

    @Test("The original rule writes no key; the new rule writes panLaw: equalPower and round-trips")
    func onlyTheNewRuleIsWritten() throws {
        let original = try JSONEncoder().encode(Self.document(panLaw: .balance))
        #expect(!String(decoding: original, as: UTF8.self).contains("panLaw"))
        let new = Self.document(panLaw: .equalPower)
        #expect(try Self.json(new)["panLaw"] as? String == "equalPower")
        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(new))
        #expect(decoded.panLaw == .equalPower)
        #expect(decoded.runtimePanLaw == .equalPower)
        #expect(PanLaw.newSong == .equalPower, "the user's pick: new songs use the automation rule")
        #expect(PanLaw.savedSongDefault == .balance, "the user's pick: saved songs keep their sound")
    }

    @Test("A pan rule this build cannot read never fails the open: original rule plus a plain warning")
    func unreadableRuleFallsBackLoudly() throws {
        for raw in ["\"fancyLaw\"", "42"] {
            var text = String(decoding: try JSONEncoder().encode(Self.document(panLaw: .balance)), as: UTF8.self)
            text.removeLast()   // the closing brace
            text += ",\"panLaw\":\(raw)}"
            let decoded = try JSONDecoder().decode(ProjectDocument.self, from: Data(text.utf8))
            #expect(decoded.panLaw == nil, "\(raw)")
            #expect(decoded.runtimePanLaw == .balance, "\(raw)")
            #expect(decoded.panLawUnreadOnLoad == (raw == "42" ? "(not text)" : "fancyLaw"))
            let warnings = decoded.runtimeState(bundleURL: FileManager.default.temporaryDirectory).warnings
            #expect(warnings.count == 1 && warnings[0].contains("pan setting"), "\(warnings)")
        }
    }
}

/// A spy that records the store's pan-rule pushes (the `MODPEngineSpy` shape; the defaults cover the rest).
@MainActor
final class PanLawEngineSpy: AudioEngineControlling {
    var panLawPushes: [PanLaw] = []
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    func panLawChanged(_ law: PanLaw) { panLawPushes.append(law) }

    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double, to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    var recordPermission: RecordPermission = .granted
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
    func setInputDevice(uid: String?) throws {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
}

extension PersistenceTests {
    @Test("m39-panlaw-new: a store starts on the original rule; New Project is a new song, saved WITH the key")
    func panLawNewProjectIsANewSong() throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MODPStore.make(in: dir)
        #expect(store.panLaw == .balance, "a store a test or tool builds keeps the original rule")
        #expect(ProjectStore(panLaw: .newSong).panLaw == .equalPower, "the app's launch store asks for it")
        let spy = PanLawEngineSpy()
        store.engine = spy
        #expect(spy.panLawPushes == [.balance], "attaching the engine pushes the store's rule")
        try store.newProject(discardChanges: true)
        #expect(store.panLaw == .equalPower)
        #expect(spy.panLawPushes.last == .equalPower, "New Project tells the engine")
        store.addTrack(name: "Pan")
        let path = dir.appendingPathComponent("New Song.dawproj").path
        _ = try store.saveProject(to: path)
        let text = try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("project.json"),
                              encoding: .utf8)
        // POSITIVE CONTROL for the saved-song gate's `!json.contains("panLaw")`: a new song's file DOES carry it.
        #expect(text.contains("panLaw") && text.contains("equalPower"), "a new song saved without its rule")
        #expect(store.buildAutosaveDocument().panLaw == .equalPower, "the crash autosave carries the rule")

        let opener = MODPStore.make(in: dir)
        let openSpy = PanLawEngineSpy()
        opener.engine = openSpy
        _ = try opener.openProject(at: path, discardChanges: true)
        #expect(opener.panLaw == .equalPower, "a new song reopens as a new song")
        #expect(openSpy.panLawPushes.last == .equalPower)
    }

    @Test("m39-panlaw-new: a song saved without the key opens on the original rule, and the engine hears it")
    func panLawSavedSongOpensOnTheOriginalRule() throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saver = MODPStore.make(in: dir)
        saver.addTrack(name: "Old")
        let path = dir.appendingPathComponent("Old Song.dawproj").path
        _ = try saver.saveProject(to: path)
        let text = try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("project.json"),
                              encoding: .utf8)
        #expect(!text.contains("panLaw"), "a song on the original rule writes no key")

        let store = MODPStore.make(in: dir)
        let spy = PanLawEngineSpy()
        store.engine = spy
        try store.newProject(discardChanges: true)
        #expect(store.panLaw == .equalPower, "control: the store held the new rule before the open")
        _ = try store.openProject(at: path, discardChanges: true)
        #expect(store.tracks.map { $0.name } == ["Old"], "control: the open really happened")
        #expect(store.panLaw == .balance, "a saved song must open on the ORIGINAL rule")
        #expect(spy.panLawPushes.last == .balance, "the engine must hear the original rule")
    }

    @Test("m39-panlaw-new: crash recovery brings a new song back as a new song")
    func panLawCrashRecoveryKeepsTheRule() async throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crashed = MODPStore.make(in: dir)
        try crashed.newProject(discardChanges: true)
        _ = crashed.beginCrashDetection()
        crashed.addTrack(name: "Unsaved")  // an unsaved edit, so the autosave writes
        await crashed.autosaveTick()

        let relaunched = MODPStore.make(in: dir)
        #expect(relaunched.panLaw == .balance, "control: a fresh store starts on the original rule")
        let spy = PanLawEngineSpy()
        relaunched.engine = spy
        #expect(relaunched.beginCrashDetection(), "control: the first session's lock must read as a crash")
        _ = try relaunched.recoverFromAutosave(accept: true)
        #expect(relaunched.tracks.map { $0.name } == ["Unsaved"], "control: the recovery really happened")
        #expect(relaunched.panLaw == .equalPower, "crash recovery lost the new song's pan rule")
        #expect(spy.panLawPushes.last == .equalPower)
    }
}
