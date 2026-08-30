import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift) from the DAWCoreTests target.

/// m24-n — the voice a converted track was made from travels WITH the project.
///
/// ⭐ **The load-bearing test in this file is `roundTripSurvivesSaveAndReopen`,
/// and it is a ROUND TRIP on purpose.** A field can be added to `Track`,
/// mutate correctly, read back correctly in memory, and still VANISH on save,
/// because `ProjectDocument`/`TrackDocument` enumerate their fields and coding
/// keys EXPLICITLY — there is no synthesis to carry a new one along. A unit
/// test on the model would pass on exactly that defect. So the gate is:
/// convert → save → REOPEN IN A FRESH STORE → the provenance is still there and
/// the embedded voice is present and installable.
///
/// **Everything here is hermetic.** The voice "models" are four-byte files in a
/// temp directory and `voiceStoreDirectory` is pointed at it, so no test reads
/// or writes the user's real `~/Library/Application Support/DAWPro/VoiceModels`
/// — which, unlike a scratch autosave, holds large assets a training run
/// produced.
@MainActor
@Suite("Voice provenance + project-embedded voice models (m24-n)")
struct VoiceProvenanceEmbeddingTests {

    // MARK: - Fixtures

    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m24n-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a voice folder into `store` with the given file names. Contents
    /// are distinguishable by length so a copy can be told from a stale file.
    @discardableResult
    private func makeVoice(
        _ voiceId: String, in store: URL,
        files: [String] = VoiceStore.embeddableFileNames + ["model.pth"],
        payload: String = "npz"
    ) throws -> URL {
        let dir = store.appendingPathComponent(voiceId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data("\(payload)-\(name)".utf8)
                .write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    /// A store with hermetic media and a hermetic voice store.
    private func makeStore(voiceStore: URL) -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.voiceStoreDirectory = voiceStore
        return store
    }

    private func addConvertedTrack(
        _ store: ProjectStore, name: String, provenance: VoiceProvenance
    ) -> UUID {
        var track = Track(name: name, kind: .audio)
        track.isAIGenerated = true
        track.voiceProvenance = provenance
        store.tracks.append(track)
        return track.id
    }

    private let ada = VoiceProvenance(
        voiceId: "ada", voiceName: "Ada (studio take)", pitchSemitones: -3,
        convertedAt: Date(timeIntervalSince1970: 1_700_000_000))

    // MARK: - THE GATE: convert → save → reopen

    @Test("round trip: provenance survives save→reopen AND the embedded voice is present and usable")
    func roundTripSurvivesSaveAndReopen() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)

        let path = tempDir("proj").appendingPathComponent("Ballad").path
        let saved = try store.saveProject(to: path)

        // The bundle carries the voice, in `voices/<id>/`, beside `media/`.
        let bundle = URL(fileURLWithPath: saved.path)
        let embedded = try #require(
            VoiceStore.embeddedDirectory(voiceId: "ada", bundleURL: bundle))
        #expect(FileManager.default.fileExists(
            atPath: embedded.appendingPathComponent("model.npz").path))
        #expect(VoiceStore.isUsableVoiceDirectory(embedded))
        #expect(saved.voicesEmbedded == 1)
        #expect((saved.voiceBytesCopied ?? 0) > 0)

        // REOPEN IN A FRESH STORE — the step a memory-only test never takes.
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        reopened.voiceStoreDirectory = tempDir("store-empty")   // voice NOT installed here
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty)

        let restored = try #require(reopened.tracks.first?.voiceProvenance)
        #expect(restored == ada)
        #expect(restored.voiceId == "ada")
        #expect(restored.voiceName == "Ada (studio take)")
        #expect(restored.pitchSemitones == -3)

        // …and the carried copy is USABLE: installing it into this machine's
        // (empty) store makes the voice real, which is what "re-convertible on
        // another machine" means.
        let report = reopened.embeddedVoicesReport()
        #expect(report.voices.count == 1)
        #expect(report.voices[0].embeddedInProject)
        #expect(report.voices[0].installedLocally == false)

        let installed = try reopened.installEmbeddedVoice(voiceId: "ada")
        #expect(installed.voiceName == "Ada (studio take)")
        #expect(installed.replacedExisting == false)
        #expect(VoiceStore.isUsableVoiceDirectory(
            URL(fileURLWithPath: installed.directoryPath)))
        #expect(reopened.embeddedVoicesReport().voices[0].installedLocally)
    }

    // MARK: - Persistence shape (the vanish-on-save failure mode)

    @Test("a track with no provenance encodes NO voiceProvenance key — pre-m24-n saves stay byte-identical")
    func absentWhenNil() throws {
        let plain = TrackDocument(from: Track(name: "Drums", kind: .audio), mediaRefs: [:])
        let json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(json["voiceProvenance"] == nil)

        // Positive control: the key IS emitted when the fact exists, so the
        // absence above means "no provenance", not "the encoder cannot".
        var converted = Track(name: "Voice: ada", kind: .audio)
        converted.voiceProvenance = ada
        let withProvenance = TrackDocument(from: converted, mediaRefs: [:])
        let json2 = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(withProvenance)) as? [String: Any])
        let block = try #require(json2["voiceProvenance"] as? [String: Any])
        #expect(block["voiceId"] as? String == "ada")
        #expect(block["pitchSemitones"] as? Int == -3)
    }

    @Test("a pre-m24-n track document decodes with nil provenance instead of failing")
    func legacyDocumentDecodes() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"Old","kind":"audio","volume":1,"pan":0,"isMuted":false,"isSoloed":false,"isArmed":false,"isAIGenerated":false,"clips":[]}"#
        let decoded = try JSONDecoder().decode(
            TrackDocument.self, from: Data(legacy.utf8))
        #expect(decoded.voiceProvenance == nil)
        #expect(decoded.name == "Old")
    }

    @Test("provenance rides Track's own Codable too — which is what puts it on project.snapshot")
    func trackCodableCarriesProvenance() throws {
        var converted = Track(name: "Voice: ada", kind: .audio)
        converted.voiceProvenance = ada
        let data = try JSONEncoder().encode(converted)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["voiceProvenance"] != nil)
        #expect(try JSONDecoder().decode(Track.self, from: data).voiceProvenance == ada)

        // Omitted when nil — a snapshot of a project with no converted track
        // stays byte-identical to its pre-m24-n shape.
        let plain = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(Track(name: "Drums"))) as? [String: Any]
        #expect(plain?["voiceProvenance"] == nil)
    }

    // MARK: - Which files travel

    @Test("model.pth is NOT embedded — the converter never reads it and it is ~45% of the folder")
    func modelPthIsExcluded() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let path = tempDir("proj").appendingPathComponent("Ballad").path
        let saved = try store.saveProject(to: path)

        let embedded = try #require(VoiceStore.embeddedDirectory(
            voiceId: "ada", bundleURL: URL(fileURLWithPath: saved.path)))
        let names = Set((try FileManager.default.contentsOfDirectory(
            at: embedded, includingPropertiesForKeys: nil)).map(\.lastPathComponent))
        #expect(names == Set(["model.npz", "model.json", "model.index", "voice.json"]))
        #expect(!names.contains("model.pth"))
        // Positive control: it WAS in the source folder, so its absence above
        // is a decision, not a missing fixture.
        #expect(FileManager.default.fileExists(atPath: voiceStore
            .appendingPathComponent("ada/model.pth").path))
    }

    @Test("a voice with no model.npz cannot be embedded — an index alone is not a voice")
    func indexOnlyVoiceIsNotEmbeddable() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore, files: ["model.index", "voice.json"])
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let saved = try store.saveProject(
            to: tempDir("proj").appendingPathComponent("Ballad").path)
        #expect(saved.voicesEmbedded == 0)
        #expect(saved.warnings.contains { $0.contains("not in this machine's voice store") })
    }

    // MARK: - Dedupe, idempotency, and the cost story

    @Test("two tracks converted with the SAME voice embed ONE copy")
    func sharedVoiceEmbedsOnce() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Lead", provenance: ada)
        _ = addConvertedTrack(store, name: "Double", provenance: ada)

        let plan = ProjectBundle.planVoices(
            tracks: store.tracks,
            bundleURL: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).dawproj"),
            voiceStoreURL: voiceStore)
        #expect(plan.voices.count == 1)
        #expect(plan.copies.count == 4)          // the whitelist, once — not twice

        let saved = try store.saveProject(
            to: tempDir("proj").appendingPathComponent("Ballad").path)
        #expect(saved.voicesEmbedded == 1)
        // Both tracks are named on the one row.
        let report = store.embeddedVoicesReport()
        #expect(report.voices.count == 1)
        #expect(report.voices[0].tracks == ["Lead", "Double"])
    }

    @Test("re-saving copies ZERO voice bytes and warns nothing — the cost is announced once, when it is paid")
    func idempotentResaveIsFree() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let path = tempDir("proj").appendingPathComponent("Ballad").path

        let first = try store.saveProject(to: path)
        #expect((first.voiceBytesCopied ?? 0) > 0)
        #expect(first.warnings.contains { $0.contains("embedded 1 voice model(s)") })

        let second = try store.saveProject(to: nil)     // save in place
        #expect(second.voiceBytesCopied == 0)
        #expect(second.voiceBytes == first.voiceBytes)  // still carried
        #expect(second.voicesEmbedded == 1)
        #expect(!second.warnings.contains { $0.contains("embedded") })
    }

    @Test("a project with no converted track pays nothing and its save response is unchanged")
    func noProvenanceNoCost() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        store.tracks.append(Track(name: "Drums", kind: .audio))
        let saved = try store.saveProject(
            to: tempDir("proj").appendingPathComponent("Ballad").path)
        // Keys OMITTED entirely, not zero — a pre-m24-n response byte for byte.
        #expect(saved.voicesEmbedded == nil)
        #expect(saved.voiceBytes == nil)
        #expect(saved.voiceBytesCopied == nil)
        let json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(saved)) as? [String: Any])
        #expect(json["voicesEmbedded"] == nil)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: saved.path)
            .appendingPathComponent("voices").path) == false)
    }

    // MARK: - A missing voice is information, not a failure

    @Test("a voice that exists nowhere warns and saves anyway — the converted audio is unaffected")
    func missingVoiceIsNotAnError() throws {
        let store = makeStore(voiceStore: tempDir("store-empty"))
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let saved = try store.saveProject(
            to: tempDir("proj").appendingPathComponent("Ballad").path)

        #expect(saved.voicesEmbedded == 0)
        let warning = try #require(saved.warnings.first { $0.contains("'ada'") })
        #expect(warning.contains("still plays"))
        #expect(warning.contains("vc.importVoiceModel"))

        // The project still opens, and the record still says what the audio was
        // made from — which is the whole reason it is a snapshot, not a lookup.
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        reopened.voiceStoreDirectory = tempDir("store-empty-2")
        _ = try reopened.openProject(at: saved.path)
        #expect(reopened.tracks[0].voiceProvenance?.voiceName == "Ada (studio take)")
        let row = try #require(reopened.embeddedVoicesReport().voices.first)
        #expect(row.embeddedInProject == false)
        #expect(row.installedLocally == false)
        #expect(row.note.contains("still plays"))
    }

    @Test("Save As from a project whose voice is not on THIS machine carries the embedded copy forward")
    func saveAsFallsBackToTheOpenBundle() throws {
        // Machine A: has the voice, saves the project.
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let origin = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(origin, name: "Voice: ada", provenance: ada)
        let pathA = tempDir("projA").appendingPathComponent("Ballad").path
        _ = try origin.saveProject(to: pathA)

        // Machine B: does NOT have the voice; opens the project and saves-as.
        let elsewhere = ProjectStore()
        elsewhere.media = FakeMedia()
        elsewhere.voiceStoreDirectory = tempDir("store-empty")
        _ = try elsewhere.openProject(at: pathA)
        let pathB = tempDir("projB").appendingPathComponent("Ballad Copy").path
        let saved = try elsewhere.saveProject(to: pathB)

        #expect(saved.voicesEmbedded == 1)
        let embedded = try #require(VoiceStore.embeddedDirectory(
            voiceId: "ada", bundleURL: URL(fileURLWithPath: saved.path)))
        #expect(VoiceStore.isUsableVoiceDirectory(embedded))
        // …and it came from the OPEN BUNDLE, not the (empty) store.
        #expect(saved.warnings.contains { $0.contains("'ada'") } == false)
    }

    // MARK: - The builtin smoke target

    @Test("the built-in 'base' target is skipped silently — it ships with the app and cannot be installed")
    func baseIsNeverEmbedded() throws {
        let store = makeStore(voiceStore: tempDir("store-empty"))
        _ = addConvertedTrack(store, name: "Voice: base", provenance: VoiceProvenance(
            voiceId: VoiceStore.reservedVoiceId, voiceName: "Base (untrained smoke target)"))
        let saved = try store.saveProject(
            to: tempDir("proj").appendingPathComponent("Smoke").path)
        #expect(saved.voicesEmbedded == 0)
        // No "install it" advice for a thing that cannot be installed.
        #expect(saved.warnings.contains { $0.contains("base") } == false)

        let row = try #require(store.embeddedVoicesReport().voices.first)
        #expect(row.note.contains("ships with the app"))
        #expect(throws: ProjectError.self) {
            try store.installEmbeddedVoice(voiceId: VoiceStore.reservedVoiceId)
        }
    }

    // MARK: - The report

    @Test("a voice left behind by a deleted track is named as an orphan, not left mysterious")
    func orphanedVoiceIsNamed() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        let trackID = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let path = tempDir("proj").appendingPathComponent("Ballad").path
        _ = try store.saveProject(to: path)

        #expect(try store.removeTrack(id: trackID))
        _ = try store.saveProject(to: nil)

        let report = store.embeddedVoicesReport()
        #expect(report.orphanedVoiceIds == ["ada"])
        #expect(report.embeddedBytes > 0)
        let row = try #require(report.voices.first)
        #expect(row.tracks.isEmpty)
        #expect(row.note.contains("no track uses this voice any more"))
        #expect(row.note.contains("voices/ada"))
    }

    @Test("an unsaved project reports honestly: nothing embedded yet, and why")
    func unsavedProjectReport() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore)
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let report = store.embeddedVoicesReport()
        #expect(report.projectPath == nil)
        #expect(report.embeddedBytes == 0)
        #expect(report.voices[0].embeddedInProject == false)
        #expect(report.voices[0].installedLocally)
        #expect(report.voices[0].note.contains("never been saved"))
    }

    // MARK: - Installing

    @Test("installing refuses to replace an existing voice unless overwrite is asked for")
    func installRefusesToReplaceSilently() throws {
        let voiceStore = tempDir("store")
        try makeVoice("ada", in: voiceStore, payload: "original")
        let store = makeStore(voiceStore: voiceStore)
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)
        let path = tempDir("proj").appendingPathComponent("Ballad").path
        _ = try store.saveProject(to: path)

        // A DIFFERENT local voice now sits at the same id.
        try makeVoice("ada", in: voiceStore, payload: "local-retrain-please-keep")
        #expect(throws: ProjectError.self) {
            try store.installEmbeddedVoice(voiceId: "ada")
        }
        let kept = try String(contentsOf: voiceStore
            .appendingPathComponent("ada/model.npz"), encoding: .utf8)
        #expect(kept.hasPrefix("local-retrain-please-keep"))

        let replaced = try store.installEmbeddedVoice(voiceId: "ada", overwrite: true)
        #expect(replaced.replacedExisting)
        let now = try String(contentsOf: voiceStore
            .appendingPathComponent("ada/model.npz"), encoding: .utf8)
        #expect(now.hasPrefix("original"))
    }

    @Test("installing refuses legibly when the project is unsaved or carries no such voice")
    func installRefusalsTeach() throws {
        let store = makeStore(voiceStore: tempDir("store"))
        _ = addConvertedTrack(store, name: "Voice: ada", provenance: ada)

        do {
            _ = try store.installEmbeddedVoice(voiceId: "ada")
            Issue.record("expected a refusal on an unsaved project")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("never been saved") == true)
        }

        _ = try store.saveProject(to: tempDir("proj").appendingPathComponent("Ballad").path)
        do {
            _ = try store.installEmbeddedVoice(voiceId: "ada")
            Issue.record("expected a refusal when nothing was embedded")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("project.embeddedVoices") == true)
        }
    }

    @Test("a hand-edited voice id that could escape the bundle is refused, not resolved")
    func traversalIdsAreRefused() throws {
        #expect(VoiceStore.isSafeVoiceId("ada_2-b"))
        #expect(!VoiceStore.isSafeVoiceId("../../etc"))
        #expect(!VoiceStore.isSafeVoiceId(".."))
        #expect(!VoiceStore.isSafeVoiceId("a/b"))
        #expect(!VoiceStore.isSafeVoiceId(""))
        #expect(VoiceStore.embeddedDirectory(
            voiceId: "../escape", bundleURL: URL(fileURLWithPath: "/tmp/x")) == nil)

        let store = makeStore(voiceStore: tempDir("store"))
        _ = addConvertedTrack(store, name: "Bad", provenance: VoiceProvenance(
            voiceId: "../escape", voiceName: "hand-edited"))
        let saved = try store.saveProject(
            to: tempDir("proj").appendingPathComponent("Ballad").path)
        #expect(saved.voicesEmbedded == 0)
        #expect(saved.warnings.contains { $0.contains("not a usable folder name") })
    }

    // MARK: - The one home

    @Test("the voice store has ONE home: VoiceStore.directory is the voiceModels category")
    func oneHomeForTheVoiceStore() {
        #expect(VoiceStore.directory == AppDirectories.applicationSupport(.voiceModels))
        #expect(VoiceStore.bundleFolderName == "voices")
        #expect(VoiceStore.requiredFileName == "model.npz")
        #expect(VoiceStore.reservedVoiceId == "base")
        // The whitelist, pinned: adding model.pth here would silently inflate
        // every project by ~45%.
        #expect(VoiceStore.embeddableFileNames
            == ["model.npz", "model.json", "model.index", "voice.json"])
    }
}
