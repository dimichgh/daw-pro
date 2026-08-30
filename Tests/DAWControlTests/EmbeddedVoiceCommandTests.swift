import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for m24-n's two verbs: `project.embeddedVoices`
/// (what is this project carrying, and why) and `vc.installEmbeddedVoice`
/// (make a carried copy usable on THIS machine).
///
/// ⭐ **Why these two and no others.** Provenance itself needed NO new wire
/// verb: it lives on `Track`, so it already rides `project.snapshot` through
/// `Track`'s own `Codable` (⚠️ MEASURED — there is no `track.describe` in this
/// wire; the snapshot IS the per-track read surface), and it is WRITTEN by the
/// conversion that already has a verb (`vc.convertClips`). These two exist
/// because neither question they answer is expressible on the existing surface
/// — one is about the SAVED BUNDLE's contents, the other writes the app's voice
/// store.
///
/// Hermetic: `voiceModelImportDirectory` is a scratch temp dir, and the router
/// points the store's `voiceStoreDirectory` at the same URL, so nothing here
/// reads or writes the real Application Support voice store.
@MainActor
@Suite("Embedded voices over the wire (m24-n)")
struct EmbeddedVoiceCommandTests {

    private func scratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m24n-cmd-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeVoice(_ voiceId: String, in store: URL) throws {
        let dir = store.appendingPathComponent(voiceId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in VoiceStore.embeddableFileNames {
            try Data("payload-\(name)".utf8).write(to: dir.appendingPathComponent(name))
        }
    }

    private let ada = VoiceProvenance(
        voiceId: "ada", voiceName: "Ada (studio take)", pitchSemitones: 2,
        convertedAt: Date(timeIntervalSince1970: 1_700_000_000))

    /// A router over a store carrying one converted track, with a hermetic
    /// voice store the router itself installs onto the store.
    private func makeSession(withVoice: Bool = true)
        throws -> (ProjectStore, CommandRouter, URL) {
        let voiceStore = try scratchDir("store")
        if withVoice { try makeVoice("ada", in: voiceStore) }
        let store = ProjectStore()
        store.media = FakeMedia()
        // Through the PUBLIC store API — this suite is outside DAWCore, which
        // is the same door the app and the wire come through.
        let track = store.addTrack(name: "Voice: ada", kind: .audio)
        _ = store.updateTrack(id: track.id) {
            $0.isAIGenerated = true
            $0.voiceProvenance = self.ada
        }
        let router = CommandRouter(store: store, voiceModelImportDirectory: voiceStore)
        return (store, router, voiceStore)
    }

    // MARK: - Registry

    @Test("both verbs are canonical, additive at the very end of allCommands")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("project.embeddedVoices"))
        #expect(CommandRouter.allCommands.contains("vc.installEmbeddedVoice"))
        #expect(CommandRouter.allCommands.dropLast().last == "project.embeddedVoices")
        #expect(CommandRouter.allCommands.last == "vc.installEmbeddedVoice")
        // ADDITIVE ONLY: every neighbour they were placed beside is untouched.
        for name in ["project.snapshot", "project.open", "project.save",
                     "vc.importVoiceModel", "vc.convertClips", "vc.listVoices"] {
            #expect(CommandRouter.allCommands.contains(name))
        }
    }

    @Test("the router points the STORE's voice store at its own — one directory, not two")
    func oneVoiceStorePerRouter() throws {
        let (store, _, voiceStore) = try makeSession()
        #expect(store.voiceStoreDirectory == voiceStore)
    }

    // MARK: - project.embeddedVoices

    @Test("reports what an UNSAVED project will carry, and says why nothing is embedded yet")
    func reportsUnsavedProject() async throws {
        let (_, router, _) = try makeSession()
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.embeddedVoices", params: [:]))
        #expect(response.ok, "project.embeddedVoices failed: \(response.error ?? "?")")

        #expect(response.result?["projectPath"] == nil || response.result?["projectPath"] == .null)
        #expect(response.result?["embeddedBytes"]?.doubleValue == 0)
        #expect(response.result?["orphanedVoiceIds"]?.arrayValue?.isEmpty == true)
        let voices = try #require(response.result?["voices"]?.arrayValue)
        #expect(voices.count == 1)
        let row = try #require(voices.first?.objectValue)
        #expect(row["voiceId"]?.stringValue == "ada")
        #expect(row["voiceName"]?.stringValue == "Ada (studio take)")
        #expect(row["tracks"]?.arrayValue?.first?.stringValue == "Voice: ada")
        #expect(row["embeddedInProject"]?.boolValue == false)
        #expect(row["installedLocally"]?.boolValue == true)
        #expect(row["note"]?.stringValue?.contains("never been saved") == true)
    }

    @Test("after a save it reports the carried copy and its byte cost")
    func reportsSavedProject() async throws {
        let (store, router, _) = try makeSession()
        let path = try scratchDir("proj").appendingPathComponent("Ballad").path
        let saved = try store.saveProject(to: path)
        #expect(saved.voicesEmbedded == 1)

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.embeddedVoices", params: [:]))
        #expect(response.ok)
        #expect(response.result?["projectPath"]?.stringValue == saved.path)
        #expect((response.result?["embeddedBytes"]?.doubleValue ?? 0) > 0)
        let row = try #require(response.result?["voices"]?.arrayValue?.first?.objectValue)
        #expect(row["embeddedInProject"]?.boolValue == true)
        #expect(row["installedLocally"]?.boolValue == true)
        #expect(row["note"]?.stringValue?.contains("anyone you send the project to") == true)
    }

    @Test("a project with no converted track answers with an empty, honest report — not an error")
    func emptyProjectReportsEmpty() async throws {
        let router = CommandRouter(store: ProjectStore(),
                                   voiceModelImportDirectory: try scratchDir("store"))
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.embeddedVoices", params: [:]))
        #expect(response.ok)
        #expect(response.result?["voices"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["embeddedBytes"]?.doubleValue == 0)
    }

    @Test("project.embeddedVoices takes no parameters and says so")
    func readRejectsUnknownKeys() async throws {
        let (_, router, _) = try makeSession()
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.embeddedVoices", params: ["voiceId": .string("ada")]))
        #expect(!response.ok)
        #expect(response.error?.contains("voiceId") == true)
        #expect(response.error?.contains("project.embeddedVoices") == true)
    }

    // MARK: - vc.installEmbeddedVoice

    @Test("installs the carried copy into this machine's voice store and reports what landed")
    func installsIntoTheVoiceStore() async throws {
        // A project saved on a machine that HAD the voice…
        let (store, _, voiceStore) = try makeSession()
        let path = try scratchDir("proj").appendingPathComponent("Ballad").path
        _ = try store.saveProject(to: path)

        // …reopened on one that does NOT.
        let elsewhereStore = ProjectStore()
        elsewhereStore.media = FakeMedia()
        let emptyVoiceStore = try scratchDir("store-empty")
        let router = CommandRouter(store: elsewhereStore,
                                   voiceModelImportDirectory: emptyVoiceStore)
        _ = try elsewhereStore.openProject(at: path)
        #expect(!VoiceStore.isUsableVoiceDirectory(
            emptyVoiceStore.appendingPathComponent("ada")))

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.installEmbeddedVoice",
            params: ["voiceId": .string("ada")]))
        #expect(response.ok, "vc.installEmbeddedVoice failed: \(response.error ?? "?")")
        #expect(response.result?["voiceId"]?.stringValue == "ada")
        #expect(response.result?["voiceName"]?.stringValue == "Ada (studio take)")
        #expect(response.result?["replacedExisting"]?.boolValue == false)
        #expect((response.result?["byteCount"]?.doubleValue ?? 0) > 0)
        let files = try #require(response.result?["files"]?.arrayValue)
        #expect(files.compactMap(\.stringValue) == VoiceStore.embeddableFileNames)

        // The voice is now REAL where the sidecar looks for it.
        #expect(VoiceStore.isUsableVoiceDirectory(
            emptyVoiceStore.appendingPathComponent("ada")))
        // …and the untouched origin store still has its own copy.
        #expect(VoiceStore.isUsableVoiceDirectory(voiceStore.appendingPathComponent("ada")))

        // Installing a voice is not an EDIT: it never dirties the session (the
        // project just opened clean) and leaves nothing to undo.
        #expect(elsewhereStore.isDirty == false)
        #expect(elsewhereStore.snapshot().undoLabel == nil)
    }

    @Test("refuses to replace an installed voice unless overwrite is asked for")
    func refusesSilentReplacement() async throws {
        let (store, router, _) = try makeSession()
        _ = try store.saveProject(
            to: try scratchDir("proj").appendingPathComponent("Ballad").path)

        // The voice is ALREADY in this machine's store (makeSession put it there).
        let refused = await router.handle(ControlRequest(
            id: "1", command: "vc.installEmbeddedVoice",
            params: ["voiceId": .string("ada")]))
        #expect(!refused.ok)
        #expect(refused.error?.contains("already in this machine's voice store") == true)
        #expect(refused.error?.contains("overwrite") == true)

        let forced = await router.handle(ControlRequest(
            id: "2", command: "vc.installEmbeddedVoice",
            params: ["voiceId": .string("ada"), "overwrite": .bool(true)]))
        #expect(forced.ok, "overwrite install failed: \(forced.error ?? "?")")
        #expect(forced.result?["replacedExisting"]?.boolValue == true)
    }

    @Test("a voice the project does not carry refuses by pointing at the report, not by failing obscurely")
    func unknownVoiceTeaches() async throws {
        let (store, router, _) = try makeSession()
        _ = try store.saveProject(
            to: try scratchDir("proj").appendingPathComponent("Ballad").path)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.installEmbeddedVoice",
            params: ["voiceId": .string("nobody")]))
        #expect(!response.ok)
        #expect(response.error?.contains("project.embeddedVoices") == true)
    }

    @Test("params: voiceId is required and unknown keys are refused")
    func paramShape() async throws {
        let (_, router, _) = try makeSession()
        let missing = await router.handle(ControlRequest(
            id: "1", command: "vc.installEmbeddedVoice", params: [:]))
        #expect(!missing.ok)
        #expect(missing.error?.contains("voiceId") == true)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "vc.installEmbeddedVoice",
            params: ["voiceId": .string("ada"), "force": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("force") == true)
        #expect(unknown.error?.contains("vc.installEmbeddedVoice") == true)
    }

    // MARK: - Provenance needs no verb of its own

    @Test("provenance already rides project.snapshot — no third verb was added for READING it")
    func provenanceRidesExistingReads() async throws {
        let (store, router, _) = try makeSession()

        let snapshot = await router.handle(ControlRequest(
            id: "1", command: "project.snapshot", params: [:]))
        #expect(snapshot.ok)
        let track = try #require(snapshot.result?["tracks"]?.arrayValue?.first?.objectValue)
        #expect(track["voiceProvenance"]?["voiceId"]?.stringValue == "ada")
        #expect(track["voiceProvenance"]?["voiceName"]?.stringValue == "Ada (studio take)")
        #expect(track["voiceProvenance"]?["pitchSemitones"]?.doubleValue == 2)
        #expect(track["voiceProvenance"]?["convertedAt"] != nil)

        // ⚠️ MEASURED, not assumed: this wire has NO per-track describe verb, so
        // `project.snapshot` is the read surface and nothing else had to grow.
        #expect(!CommandRouter.allCommands.contains("track.describe"))

        // A plain track carries no key at all — pre-m24-n payloads are unchanged.
        _ = store.addTrack(name: "Drums", kind: .audio)
        let snapshot2 = await router.handle(ControlRequest(
            id: "2", command: "project.snapshot", params: [:]))
        let plain = try #require(snapshot2.result?["tracks"]?.arrayValue?.last?.objectValue)
        #expect(plain["voiceProvenance"] == nil)
    }
}
