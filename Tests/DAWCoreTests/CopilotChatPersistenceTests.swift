import Foundation
import Testing
@testable import DAWCore

/// Chat-persist design, Phase A (docs/research/design-copilot-chat-persistence.md):
/// the `CopilotChatDocument` DTOs, the additive-optional `ProjectDocument.copilotChats`
/// field (omit-when-empty, LOSSY per-element decode), the ProjectStore chat verbs +
/// caps, and the chat-dirty plumbing through every autosave/flush/boundary path.
/// All headless — the engine-side laws (L1/L2/L3, archive-on-reset) live in
/// DAWControlTests.
@MainActor
@Suite("Copilot chat persistence (chat-persist Phase A)")
struct CopilotChatPersistenceTests {
    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whole-second dates: `project.json` rides ISO8601 (sub-second precision
    /// would not round-trip, so tests never use `Date()` for equality).
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    /// A fully populated chat — every entry kind, every block type.
    private func sampleChat(
        id: UUID = UUID(),
        title: String = "add a funky bassline",
        updatedAt: TimeInterval = 1_000,
        droppedEntries: Int? = nil
    ) -> CopilotChatDocument {
        CopilotChatDocument(
            id: id, title: title,
            createdAt: date(500), updatedAt: date(updatedAt),
            model: "claude-sonnet-5",
            droppedEntries: droppedEntries,
            transcript: [
                .init(turnId: "t1", kind: "user", text: "add a funky bassline"),
                .init(turnId: "t1", kind: "thinking", text: "considering a slap groove..."),
                .init(turnId: "t1", kind: "toolCall", command: "track.add", summary: #"{"name":"Bass"}"#),
                .init(turnId: "t1", kind: "toolResult", command: "track.add", ok: true, summary: #"{"id":"..."}"#),
                .init(turnId: "t1", kind: "assistant", text: "Added a bass track."),
                .init(turnId: "t1", kind: "failure", text: "tool-round limit (1) reached"),
            ],
            providerMessages: [
                .init(role: "user", blocks: [.init(type: "text", text: "add a funky bassline")]),
                .init(role: "assistant", blocks: [
                    .init(type: "text", text: "On it."),
                    .init(type: "toolUse", toolUseId: "call_1", name: "track_add", inputJSON: #"{"name":"Bass"}"#),
                ]),
                .init(role: "user", blocks: [
                    .init(type: "toolResult", toolUseId: "call_1", content: #"{"id":"..."}"#, isError: true),
                ]),
            ])
    }

    private func readProjectJSON(bundlePath: String) throws -> String {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("project.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 1. DTO round trip

    @Test("CopilotChatDocument round-trips every entry kind and block type through ISO8601 JSON")
    func chatDocumentRoundTrip() throws {
        let chat = sampleChat(droppedEntries: 7)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CopilotChatDocument.self, from: encoder.encode(chat))
        #expect(decoded == chat)
    }

    @Test("nil optionals (model, droppedEntries, entry/block fields) are omitted from the encoded JSON")
    func nilFieldsAreOmitted() throws {
        var chat = sampleChat()
        chat.model = nil
        chat.droppedEntries = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(chat), as: UTF8.self)
        #expect(!json.contains("\"model\""))
        #expect(!json.contains("\"droppedEntries\""))
        // A user entry carries no command/ok/summary keys.
        #expect(!json.contains("\"ok\":null"))
    }

    // MARK: - 2. ProjectDocument: absent key / omit-when-empty

    @Test("a pre-chat document decodes with nil chats and zero dropped; empty chats omit the key on encode")
    func absentAndEmptyChats() throws {
        let document = ProjectDocument(
            name: "Legacy", transport: TransportState(), tracks: [],
            masterVolume: 1, mediaRefs: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(document), as: UTF8.self)
        // Omit-when-empty: a pre-chat project stays byte-identical (no new key).
        #expect(!json.contains("copilotChats"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectDocument.self, from: Data(json.utf8))
        #expect(decoded.copilotChats == nil)
        #expect(decoded.copilotChatsDroppedOnLoad == 0)
    }

    // MARK: - 3. Bundle round trip

    @Test("archived chats survive save → open through the real bundle, and open resets chat-dirty")
    func bundleRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let chatA = sampleChat(title: "first chat", updatedAt: 1_000)
        let chatB = sampleChat(title: "second chat", updatedAt: 2_000)
        store.archiveCopilotChat(chatA)
        store.archiveCopilotChat(chatB)
        store.addTrack(name: "Bass")
        let path = dir.appendingPathComponent("Chats").path
        _ = try store.saveProject(to: path)
        #expect(!store.chatsDirty)  // the save carried the chats

        let reopened = ProjectStore()
        _ = try reopened.openProject(at: path)
        #expect(reopened.copilotChats.count == 2)
        #expect(reopened.copilotChats.contains(chatA))
        #expect(reopened.copilotChats.contains(chatB))
        #expect(!reopened.chatsDirty)
    }

    @Test("the save-time provider closure upserts the ACTIVE chat into the persisted array")
    func activeChatProviderJoinsTheSave() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.archiveCopilotChat(sampleChat(title: "archived", updatedAt: 1_000))
        let active = sampleChat(title: "active conversation", updatedAt: 3_000)
        store.copilotActiveChatProvider = { active }

        let path = dir.appendingPathComponent("Active").path
        _ = try store.saveProject(to: path)

        let document = try ProjectBundle.read(from: ProjectBundle.normalizedBundleURL(fromPath: path))
        let titles = (document.copilotChats ?? []).map(\.title)
        #expect(titles == ["archived", "active conversation"])  // updatedAt ascending
    }

    // MARK: - 4. Lossy decode

    @Test("one corrupt chat element is skipped and counted — the open never fails, the others survive")
    func lossyDecodeSkipsCorruptElement() throws {
        let document = ProjectDocument(
            name: "Lossy", transport: TransportState(), tracks: [],
            masterVolume: 1, mediaRefs: [:],
            copilotChats: [sampleChat(title: "keep me A"), sampleChat(title: "keep me B")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: encoder.encode(document)) as! [String: Any]
        var chats = object["copilotChats"] as! [Any]
        chats.insert(["corrupt": true], at: 1)  // no id/title/... → element decode fails
        object["copilotChats"] = chats

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ProjectDocument.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.copilotChats?.count == 2)
        #expect(decoded.copilotChats?.map(\.title) == ["keep me A", "keep me B"])
        #expect(decoded.copilotChatsDroppedOnLoad == 1)
    }

    @Test("an open with a corrupt chat element surfaces the dropped count as a warning")
    func openSurfacesDroppedChatWarning() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.archiveCopilotChat(sampleChat(title: "survivor"))
        store.addTrack(name: "T")
        let path = dir.appendingPathComponent("Warn").path
        _ = try store.saveProject(to: path)

        // Corrupt one chat element in place, on disk.
        let jsonURL = ProjectBundle.normalizedBundleURL(fromPath: path)
            .appendingPathComponent("project.json")
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: jsonURL)) as! [String: Any]
        var chats = object["copilotChats"] as! [Any]
        chats.append(["corrupt": true])
        object["copilotChats"] = chats
        try JSONSerialization.data(withJSONObject: object).write(to: jsonURL)

        let reopened = ProjectStore()
        let warnings = try reopened.openProject(at: path)
        #expect(reopened.copilotChats.map(\.title) == ["survivor"])
        #expect(warnings.contains { $0.contains("1 copilot chats could not be read") })
    }

    // MARK: - 5. Store verbs

    @Test("archive upserts by id — a re-archived chat replaces its record, never duplicates")
    func archiveUpsertsById() {
        let store = ProjectStore()
        var chat = sampleChat(title: "v1")
        #expect(store.archiveCopilotChat(chat) == nil)
        chat.title = "v2"
        #expect(store.archiveCopilotChat(chat) == nil)
        #expect(store.copilotChats.count == 1)
        #expect(store.copilotChats.first?.title == "v2")
    }

    @Test("archiving at the cap evicts the oldest-updatedAt chat and returns its id — never the newcomer")
    func evictionAtCapReturnsOldestId() {
        let store = ProjectStore()
        var seeded: [CopilotChatDocument] = []
        for index in 0..<CopilotChatLimits.maxArchivedChats {
            let chat = sampleChat(title: "chat \(index)", updatedAt: 1_000 + TimeInterval(index))
            seeded.append(chat)
            #expect(store.archiveCopilotChat(chat) == nil)
        }
        // Newcomer with the OLDEST updatedAt of all: eviction must still pick
        // the oldest PREVIOUSLY archived chat — "archive" never destroys the
        // conversation it was asked to keep.
        let newcomer = sampleChat(title: "resumed ancient chat", updatedAt: 1)
        let evicted = store.archiveCopilotChat(newcomer)
        #expect(evicted == seeded[0].id)
        #expect(store.copilotChats.count == CopilotChatLimits.maxArchivedChats)
        #expect(store.copilotChats.contains { $0.id == newcomer.id })
        #expect(!store.copilotChats.contains { $0.id == seeded[0].id })
    }

    @Test("take removes and returns; remove and rename report unknown ids; rename clamps to 120 chars")
    func takeRemoveRename() {
        let store = ProjectStore()
        let chat = sampleChat()
        store.archiveCopilotChat(chat)

        #expect(store.takeCopilotChat(id: UUID()) == nil)
        #expect(store.copilotChats.count == 1)

        #expect(store.renameCopilotChat(id: UUID(), title: "nope") == false)
        let longTitle = String(repeating: "x", count: 500)
        #expect(store.renameCopilotChat(id: chat.id, title: longTitle))
        #expect(store.copilotChats.first?.title.count == CopilotChatLimits.maxTitleLength)

        let taken = store.takeCopilotChat(id: chat.id)
        #expect(taken?.id == chat.id)
        #expect(store.copilotChats.isEmpty)

        store.archiveCopilotChat(chat)
        #expect(store.removeCopilotChat(id: UUID()) == false)
        #expect(store.removeCopilotChat(id: chat.id))
        #expect(store.copilotChats.isEmpty)
    }

    // MARK: - 6. L4 — chats never touch dirty/journal/undo

    @Test("chat mutations bump chatRevision + chatsDirty ONLY — isDirty, undo, and the journal stay untouched")
    func chatMutationsNeverJournal() {
        let store = ProjectStore()
        let revisionBefore = store.chatRevision
        store.archiveCopilotChat(sampleChat())
        store.noteCopilotChatActivity()

        #expect(store.chatRevision > revisionBefore)
        #expect(store.chatsDirty)
        #expect(!store.isDirty)              // the musical-work flag is untouched
        #expect(!store.canUndo)              // no undo entry (L4)
        #expect(store.undoLabel == nil)
        #expect(store.lastEditEvent == nil)  // no journaled edit event
    }

    // MARK: - 7. Autosave / flush plumbing

    @Test("chat-only dirty drives the titled in-place autosave, which persists the chats and clears chatsDirty")
    func chatOnlyDirtyTitledAutosave() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack(name: "T")
        let path = dir.appendingPathComponent("Titled").path
        _ = try store.saveProject(to: path)
        #expect(!store.isDirty)

        store.archiveCopilotChat(sampleChat(title: "autosaved chat"))
        #expect(store.chatsDirty)
        store.autosaveIfNeeded()
        #expect(!store.chatsDirty)
        #expect(!store.isDirty)

        let document = try ProjectBundle.read(from: ProjectBundle.normalizedBundleURL(fromPath: path))
        #expect(document.copilotChats?.map(\.title) == ["autosaved chat"])
    }

    @Test("chat-only dirty drives the untitled recovery-bundle autosave, which carries the chats and stays dirty")
    func chatOnlyDirtyUntitledAutosave() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.autosaveRecoveryDirectory = dir
        store.archiveCopilotChat(sampleChat(title: "recovered chat"))

        store.autosaveIfNeeded()

        let bundles = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("Untitled-") && $0.pathExtension == "dawproj" } ?? []
        #expect(bundles.count == 1)
        let document = try ProjectBundle.read(from: bundles[0])
        #expect(document.copilotChats?.map(\.title) == ["recovered chat"])
        // A recovery snapshot is not a save: the session stays chat-dirty.
        #expect(store.chatsDirty)
    }

    @Test("a chat-only-dirty session still flushes before a transition (titled save picks up the chats)")
    func chatOnlyDirtyFlushesForTransition() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack(name: "T")
        let path = dir.appendingPathComponent("Flush").path
        _ = try store.saveProject(to: path)

        store.archiveCopilotChat(sampleChat(title: "flushed chat"))
        try store.newProject()  // no discard → flushForTransition must fire

        let document = try ProjectBundle.read(from: ProjectBundle.normalizedBundleURL(fromPath: path))
        #expect(document.copilotChats?.map(\.title) == ["flushed chat"])
        #expect(store.copilotChats.isEmpty)  // the new session starts chat-free
        #expect(!store.chatsDirty)
    }

    @Test("crash autosaveTick: chat-only dirty writes; a quiet re-tick (same chatRevision) rewrites nothing; new chat activity rewrites")
    func autosaveTickChatRevisionStaleness() async throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.crashRecovery.directory = dir
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 1_000) }

        // Chat-only dirty (isDirty false) still crash-autosaves.
        store.archiveCopilotChat(sampleChat(title: "crash chat"))
        #expect(!store.isDirty)
        await store.autosaveTick()
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(AutosaveManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.savedAt == Date(timeIntervalSince1970: 1_000))
        let document = try ProjectBundle.read(from: store.crashRecovery.autosaveBundleURL)
        #expect(document.copilotChats?.map(\.title) == ["crash chat"])

        // Quiet re-tick: chatRevision unchanged → no rewrite ("2 ticks = 1 file").
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 2_000) }
        await store.autosaveTick()
        manifest = try decoder.decode(AutosaveManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.savedAt == Date(timeIntervalSince1970: 1_000))

        // New chat activity → the high-water mark is behind → rewrite.
        store.noteCopilotChatActivity()
        await store.autosaveTick()
        manifest = try decoder.decode(AutosaveManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.savedAt == Date(timeIntervalSince1970: 2_000))
    }

    // MARK: - 8. Session boundaries

    @Test("newProject clears chats, resets chat-dirty, bumps projectGeneration, and fires the boundary handler")
    func newProjectBoundary() throws {
        let store = ProjectStore()
        var boundaryCalls = 0
        store.copilotProjectBoundaryHandler = { boundaryCalls += 1 }
        store.archiveCopilotChat(sampleChat())
        let generationBefore = store.projectGeneration

        try store.newProject(discardChanges: true)

        #expect(store.copilotChats.isEmpty)
        #expect(!store.chatsDirty)
        #expect(store.projectGeneration == generationBefore + 1)
        #expect(boundaryCalls == 1)
    }

    @Test("openProject swaps in the file's chats, bumps projectGeneration, and fires the boundary handler")
    func openProjectBoundary() throws {
        let dir = tempDir()
        let saver = ProjectStore()
        saver.archiveCopilotChat(sampleChat(title: "from disk"))
        saver.addTrack(name: "T")
        let path = dir.appendingPathComponent("Boundary").path
        _ = try saver.saveProject(to: path)

        let store = ProjectStore()
        var boundaryCalls = 0
        store.copilotProjectBoundaryHandler = { boundaryCalls += 1 }
        store.archiveCopilotChat(sampleChat(title: "pre-open leftover"))
        let generationBefore = store.projectGeneration

        _ = try store.openProject(at: path, discardChanges: true)

        #expect(store.copilotChats.map(\.title) == ["from disk"])
        #expect(!store.chatsDirty)
        #expect(store.projectGeneration == generationBefore + 1)
        #expect(boundaryCalls == 1)
    }

    @Test("recover restores the snapshot's chats CHAT-DIRTY, bumps generation, and fires the boundary handler")
    func recoverBoundary() async throws {
        let dir = tempDir()
        let s1 = ProjectStore()
        s1.crashRecovery.directory = dir
        s1.crashRecovery.clock = { Date(timeIntervalSince1970: 1_000) }
        _ = s1.beginCrashDetection()
        s1.archiveCopilotChat(sampleChat(title: "crashed chat"))
        s1.addTrack(name: "Recovered")
        await s1.autosaveTick()

        // Relaunch on the same dir → the stale lock is a crash.
        let s2 = ProjectStore()
        s2.crashRecovery.directory = dir
        var boundaryCalls = 0
        s2.copilotProjectBoundaryHandler = { boundaryCalls += 1 }
        #expect(s2.beginCrashDetection())
        let generationBefore = s2.projectGeneration

        _ = try s2.recoverFromAutosave(accept: true)

        #expect(s2.copilotChats.map(\.title) == ["crashed chat"])
        #expect(s2.chatsDirty)  // recovered content is unsaved by definition
        #expect(s2.projectGeneration == generationBefore + 1)
        #expect(boundaryCalls == 1)
    }

    // MARK: - 9. Privacy: feedback bundle excludes chats

    @Test("the feedback bundle's project snapshot NEVER carries chats, even with includeProject: true")
    func feedbackBundleExcludesChats() throws {
        let store = ProjectStore()
        store.diagnostics.outputDir = tempDir()
        store.diagnostics.crashReportsDir = tempDir()
        store.archiveCopilotChat(sampleChat(title: "private lyrics discussion"))
        store.addTrack(name: "T")

        let summary = try store.writeFeedbackBundle(includeProject: true)
        let projectJSON = try readProjectJSON(
            bundlePath: URL(fileURLWithPath: summary.path)
                .appendingPathComponent("project.dawproject").path)
        #expect(!projectJSON.contains("copilotChats"))
        #expect(!projectJSON.contains("private lyrics discussion"))
    }

    // MARK: - 10. Save warning at the project-level chat-size threshold

    @Test("a save whose encoded chats exceed 4 MiB gains the size warning (warn, never refuse)")
    func saveWarnsOnHugeChatHistory() throws {
        let dir = tempDir()
        let store = ProjectStore()
        // One chat with ~5 MiB of transcript text (fastest way over the
        // project threshold without archiving dozens of chats).
        var chat = sampleChat(title: "huge")
        chat.transcript = [
            .init(turnId: "t1", kind: "user", text: String(repeating: "a", count: 5 * 1024 * 1024)),
        ]
        store.archiveCopilotChat(chat)
        store.addTrack(name: "T")

        let result = try store.saveProject(to: dir.appendingPathComponent("Huge").path)
        #expect(result.warnings.contains {
            $0.contains("copilot chat history is large") && $0.contains("ai.copilotDeleteChat")
        })
    }
}
