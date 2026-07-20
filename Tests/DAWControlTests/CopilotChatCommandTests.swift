import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Wire-level tests for the four chat-persist Phase C commands —
/// `ai.copilotChats` / `ai.copilotResumeChat` / `ai.copilotDeleteChat` /
/// `ai.copilotRenameChat` — plus the additive fields Phase C bolted onto
/// `ai.copilotReset` / `ai.copilotState`
/// (docs/research/design-copilot-chat-persistence.md §6). Mirrors
/// `CopilotCommandTests`'s `makeWiredRouter` precedent: a REAL `CommandRouter`
/// + `CopilotEngine` over a headless `ProjectStore`, backed by a scripted
/// `FakeCopilotProvider` (declared in `CopilotEngineTests.swift`, internal to
/// this test target) so no network/keys are involved. The engine's own
/// lifecycle semantics (archive-on-reset, resume/delete/rename, the mapping
/// laws L1-L6) are proven headlessly by `CopilotEngineTests` /
/// `CopilotChatMappingTests`; this suite proves ROUTING, param validation,
/// and the exact wire shapes/teaching-error strings §6 specifies.
///
/// `router.copilotEngine` is a WEAK backref (the two-phase DAWProApp
/// pattern) — every test below keeps its `engine` binding alive for the
/// duration of the router calls, even when the test never reads `engine`
/// itself (`_ = engine  // strong hold`), the `CopilotCommandTests`/
/// `CopilotModelCommandTests` precedent.
@MainActor
@Suite("Copilot chat-persist wire commands (Phase C)")
struct CopilotChatCommandTests {
    private func makeWiredRouter(
        scripted: [CopilotReply] = [CopilotReply(blocks: [.text("ok")], stopReason: .endTurn, provider: "fake")],
        delayNanoseconds: UInt64 = 0
    ) -> (router: CommandRouter, store: ProjectStore, engine: CopilotEngine) {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(scripted, delayNanoseconds: delayNanoseconds)
        let engine = CopilotEngine(store: store, dispatch: { await router.handle($0) }, provider: { provider })
        router.copilotEngine = engine
        return (router, store, engine)
    }

    /// A minimal archived-chat fixture. Whole-second `Date`s (no fractional
    /// component) so ISO8601 round-tripping in the wire response can be
    /// compared exactly.
    private func archivedChat(
        title: String = "archived chat", createdAt: TimeInterval = 500, updatedAt: TimeInterval = 1_000,
        model: String? = "claude-sonnet-5", droppedEntries: Int? = nil
    ) -> CopilotChatDocument {
        CopilotChatDocument(
            id: UUID(), title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            model: model,
            droppedEntries: droppedEntries,
            transcript: [
                .init(turnId: "t1", kind: "user", text: "remember xyzzy"),
                .init(turnId: "t1", kind: "assistant", text: "noted"),
            ],
            providerMessages: [
                .init(role: "user", blocks: [.init(type: "text", text: "remember xyzzy")]),
                .init(role: "assistant", blocks: [.init(type: "text", text: "noted")]),
            ])
    }

    // MARK: - ai.copilotChats

    @Test("ai.copilotChats on a fresh idle engine lists nothing but always reports activeChatId")
    func chatsEmpty() async throws {
        let (router, _, engine) = makeWiredRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotChats"))
        #expect(response.ok)
        #expect(response.result?["chats"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["activeChatId"]?.stringValue == engine.currentChatID.uuidString)
    }

    @Test("ai.copilotChats lists archived + active, sorted updatedAt descending, active flagged")
    func chatsListsSortedWithActiveFlag() async throws {
        let (router, store, engine) = makeWiredRouter(scripted: [CopilotReply(
            blocks: [.text("hi")], stopReason: .endTurn, provider: "fake")])
        let older = archivedChat(title: "older", updatedAt: 100)
        let newer = archivedChat(title: "newer", updatedAt: 2_000)
        store.archiveCopilotChat(older)
        store.archiveCopilotChat(newer)

        // Give the active chat at least one entry so it's listed (§6.1: an
        // empty active chat is not noise-listed).
        _ = try engine.send("current work")
        await engine.waitForTurn()

        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotChats"))
        #expect(response.ok)
        let chats = try #require(response.result?["chats"]?.arrayValue)
        #expect(chats.count == 3)
        // The active chat's updatedAt is "now" (Date()) — always the newest here.
        #expect(chats[0]["chatId"]?.stringValue == engine.currentChatID.uuidString)
        #expect(chats[0]["active"]?.boolValue == true)
        #expect(chats[0]["title"]?.stringValue == "current work")
        #expect(chats[0]["entryCount"]?.doubleValue == 2) // user + assistant
        #expect(chats[1]["chatId"]?.stringValue == newer.id.uuidString)
        #expect(chats[1]["active"] == nil) // absent-not-false precedent
        #expect(chats[2]["chatId"]?.stringValue == older.id.uuidString)
        #expect(chats[2]["active"] == nil)
        #expect(response.result?["activeChatId"]?.stringValue == engine.currentChatID.uuidString)
    }

    @Test("ai.copilotChats row shape: model/droppedEntries present only when set/> 0")
    func chatsRowConditionalFields() async throws {
        let (router, store, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let withExtras = archivedChat(title: "with extras", model: "claude-opus-5", droppedEntries: 12)
        let withoutExtras = archivedChat(title: "plain", updatedAt: 999, model: nil, droppedEntries: nil)
        store.archiveCopilotChat(withExtras)
        store.archiveCopilotChat(withoutExtras)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotChats"))
        let chats = try #require(response.result?["chats"]?.arrayValue)
        let extrasRow = try #require(chats.first { $0["chatId"]?.stringValue == withExtras.id.uuidString })
        #expect(extrasRow["model"]?.stringValue == "claude-opus-5")
        #expect(extrasRow["droppedEntries"]?.doubleValue == 12)
        let plainRow = try #require(chats.first { $0["chatId"]?.stringValue == withoutExtras.id.uuidString })
        #expect(plainRow["model"] == nil)
        #expect(plainRow["droppedEntries"] == nil)
        // createdAt/updatedAt round-trip as ISO8601 strings.
        let formatter = ISO8601DateFormatter()
        #expect(formatter.date(from: try #require(extrasRow["createdAt"]?.stringValue)) == withExtras.createdAt)
        #expect(formatter.date(from: try #require(extrasRow["updatedAt"]?.stringValue)) == withExtras.updatedAt)
    }

    @Test("ai.copilotChats rejects unknown params")
    func chatsRejectsUnknownParams() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotChats", params: ["bogus": .string("x")]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter") == true)
    }

    // MARK: - ai.copilotResumeChat

    @Test("ai.copilotResumeChat resumes an archived chat, archives the current non-empty one, and returns the documented shape")
    func resumeHappyPath() async throws {
        let (router, store, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("first reply")], stopReason: .endTurn, provider: "fake"),
        ])
        _ = try engine.send("first conversation")
        await engine.waitForTurn()
        let firstChatID = engine.currentChatID

        let chat = archivedChat(title: "resumed chat", droppedEntries: 5)
        store.archiveCopilotChat(chat)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotResumeChat", params: ["chatId": .string(chat.id.uuidString)]))
        #expect(response.ok)
        #expect(response.result?["chatId"]?.stringValue == chat.id.uuidString)
        #expect(response.result?["title"]?.stringValue == "resumed chat")
        #expect(response.result?["entryCount"]?.doubleValue == 2)
        #expect(response.result?["droppedEntries"]?.doubleValue == 5)
        #expect(response.result?["status"]?.stringValue == "idle")
        #expect(response.result?["archivedChatId"]?.stringValue == firstChatID.uuidString)
        #expect(engine.currentChatID == chat.id)
        #expect(store.copilotChats.count == 1) // first chat took resumed chat's place in the archive
        #expect(store.copilotChats.first?.id == firstChatID)
    }

    @Test("ai.copilotResumeChat on an empty current chat omits archivedChatId and droppedEntries when there's nothing to report")
    func resumeOmitsAbsentAdditiveFields() async throws {
        let (router, store, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let chat = archivedChat(droppedEntries: nil)
        store.archiveCopilotChat(chat)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotResumeChat", params: ["chatId": .string(chat.id.uuidString)]))
        #expect(response.ok)
        #expect(response.result?["archivedChatId"] == nil) // the fresh idle current chat was empty
        #expect(response.result?["droppedEntries"] == nil)
    }

    @Test("ai.copilotResumeChat while a turn is running throws the exact teaching error and changes nothing")
    func resumeWhileRunningThrows() async throws {
        let (router, store, engine) = makeWiredRouter(
            scripted: [CopilotReply(blocks: [.text("slow")], stopReason: .endTurn, provider: "fake")],
            delayNanoseconds: 200_000_000)
        let chat = archivedChat()
        store.archiveCopilotChat(chat)
        _ = try engine.send("busy now")
        #expect(engine.status == .running)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotResumeChat", params: ["chatId": .string(chat.id.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "a copilot turn is already running — wait for it (poll ai.copilotState) "
                + "or ai.copilotReset to cancel and archive it first")
        #expect(store.copilotChats.count == 1) // untouched

        engine.cancel()
        await engine.waitForTurn()
    }

    @Test("ai.copilotResumeChat with an unknown chatId throws the teaching error")
    func resumeUnknownIDThrows() async throws {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let unknown = UUID()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotResumeChat", params: ["chatId": .string(unknown.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "unknown chatId '\(unknown.uuidString)' — list chats with ai.copilotChats")
    }

    @Test("ai.copilotResumeChat with a malformed chatId throws the exact teaching error")
    func resumeMalformedIDThrows() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotResumeChat", params: ["chatId": .string("not-a-uuid")]))
        #expect(!response.ok)
        #expect(response.error == "'chatId' must be a UUID (from ai.copilotChats)")
    }

    @Test("ai.copilotResumeChat requires chatId and rejects unknown params")
    func resumeParamValidation() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let missing = await router.handle(ControlRequest(id: "1", command: "ai.copilotResumeChat"))
        #expect(!missing.ok)

        let unknownKey = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotResumeChat",
            params: ["chatId": .string(UUID().uuidString), "bogus": .bool(true)]))
        #expect(!unknownKey.ok)
        #expect(unknownKey.error?.contains("unknown parameter") == true)
    }

    // MARK: - ai.copilotDeleteChat

    @Test("ai.copilotDeleteChat on the active chat while idle drops it permanently and mints a fresh chat")
    func deleteActiveWhileIdle() async throws {
        let (router, store, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("reply")], stopReason: .endTurn, provider: "fake"),
        ])
        _ = try engine.send("hello")
        await engine.waitForTurn()
        let activeID = engine.currentChatID

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotDeleteChat", params: ["chatId": .string(activeID.uuidString)]))
        #expect(response.ok)
        #expect(response.result?["deleted"]?.boolValue == true)
        #expect(response.result?["chatId"]?.stringValue == activeID.uuidString)
        #expect(response.result?["wasActive"]?.boolValue == true)
        #expect(engine.currentChatID != activeID)
        #expect(engine.transcript.isEmpty)
        #expect(store.copilotChats.isEmpty) // the dropped chat was never archived
    }

    @Test("ai.copilotDeleteChat on an archived chat removes it and reports wasActive: false")
    func deleteArchived() async throws {
        let (router, store, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let chat = archivedChat()
        store.archiveCopilotChat(chat)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotDeleteChat", params: ["chatId": .string(chat.id.uuidString)]))
        #expect(response.ok)
        #expect(response.result?["wasActive"]?.boolValue == false)
        #expect(store.copilotChats.isEmpty)
    }

    @Test("ai.copilotDeleteChat with an unknown chatId throws the teaching error")
    func deleteUnknownIDThrows() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let unknown = UUID()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotDeleteChat", params: ["chatId": .string(unknown.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "unknown chatId '\(unknown.uuidString)' — list chats with ai.copilotChats")
    }

    @Test("ai.copilotDeleteChat with a malformed chatId throws the exact teaching error")
    func deleteMalformedIDThrows() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotDeleteChat", params: ["chatId": .string("nope")]))
        #expect(!response.ok)
        #expect(response.error == "'chatId' must be a UUID (from ai.copilotChats)")
    }

    @Test("ai.copilotDeleteChat on the active chat while a turn is running throws the exact teaching error")
    func deleteActiveWhileRunningThrows() async throws {
        let (router, _, engine) = makeWiredRouter(
            scripted: [CopilotReply(blocks: [.text("slow")], stopReason: .endTurn, provider: "fake")],
            delayNanoseconds: 200_000_000)
        _ = try engine.send("busy now")
        #expect(engine.status == .running)
        let activeID = engine.currentChatID

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotDeleteChat", params: ["chatId": .string(activeID.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "chat '\(activeID.uuidString)' is the active conversation and a turn is running "
                + "— cancel it first (ai.copilotReset) or wait")

        engine.cancel()
        await engine.waitForTurn()
    }

    @Test("ai.copilotDeleteChat requires chatId and rejects unknown params")
    func deleteParamValidation() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let missing = await router.handle(ControlRequest(id: "1", command: "ai.copilotDeleteChat"))
        #expect(!missing.ok)

        let unknownKey = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotDeleteChat",
            params: ["chatId": .string(UUID().uuidString), "force": .bool(true)]))
        #expect(!unknownKey.ok)
        #expect(unknownKey.error?.contains("unknown parameter") == true)
    }

    // MARK: - ai.copilotRenameChat

    @Test("ai.copilotRenameChat renames the active chat")
    func renameActive() async throws {
        let (router, _, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("reply")], stopReason: .endTurn, provider: "fake"),
        ])
        _ = try engine.send("hello")
        await engine.waitForTurn()

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat",
            params: ["chatId": .string(engine.currentChatID.uuidString), "title": .string("renamed")]))
        #expect(response.ok)
        #expect(response.result?["chatId"]?.stringValue == engine.currentChatID.uuidString)
        #expect(response.result?["title"]?.stringValue == "renamed")
        #expect(engine.chatTitle == "renamed")
    }

    @Test("ai.copilotRenameChat renames an archived chat")
    func renameArchived() async throws {
        let (router, store, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let chat = archivedChat()
        store.archiveCopilotChat(chat)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat",
            params: ["chatId": .string(chat.id.uuidString), "title": .string("new archive title")]))
        #expect(response.ok)
        #expect(response.result?["title"]?.stringValue == "new archive title")
        #expect(store.copilotChats.first?.title == "new archive title")
    }

    @Test("ai.copilotRenameChat clamps an over-length title rather than erroring, and echoes the clamped value")
    func renameClampsOverLength() async throws {
        let (router, store, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let chat = archivedChat()
        store.archiveCopilotChat(chat)
        let longTitle = String(repeating: "x", count: 300)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat",
            params: ["chatId": .string(chat.id.uuidString), "title": .string(longTitle)]))
        #expect(response.ok)
        let echoed = try #require(response.result?["title"]?.stringValue)
        #expect(echoed.count == CopilotChatLimits.maxTitleLength)
        #expect(store.copilotChats.first?.title.count == CopilotChatLimits.maxTitleLength)
    }

    @Test("ai.copilotRenameChat with an empty (or whitespace-only) title throws the exact teaching error")
    func renameEmptyTitleThrows() async throws {
        let (router, store, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let chat = archivedChat()
        store.archiveCopilotChat(chat)

        let empty = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat",
            params: ["chatId": .string(chat.id.uuidString), "title": .string("")]))
        #expect(!empty.ok)
        #expect(empty.error == "'title' must not be empty")

        let whitespace = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotRenameChat",
            params: ["chatId": .string(chat.id.uuidString), "title": .string("   ")]))
        #expect(!whitespace.ok)
        #expect(whitespace.error == "'title' must not be empty")
        #expect(store.copilotChats.first?.title == "archived chat") // unchanged
    }

    @Test("ai.copilotRenameChat with an unknown chatId throws the teaching error")
    func renameUnknownIDThrows() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let unknown = UUID()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat",
            params: ["chatId": .string(unknown.uuidString), "title": .string("nope")]))
        #expect(!response.ok)
        #expect(response.error == "unknown chatId '\(unknown.uuidString)' — list chats with ai.copilotChats")
    }

    @Test("ai.copilotRenameChat with a malformed chatId throws the exact teaching error")
    func renameMalformedIDThrows() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat",
            params: ["chatId": .string("bogus-id"), "title": .string("nope")]))
        #expect(!response.ok)
        #expect(response.error == "'chatId' must be a UUID (from ai.copilotChats)")
    }

    @Test("ai.copilotRenameChat requires chatId + title and rejects unknown params")
    func renameParamValidation() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let missingTitle = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotRenameChat", params: ["chatId": .string(UUID().uuidString)]))
        #expect(!missingTitle.ok)

        let unknownKey = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotRenameChat",
            params: ["chatId": .string(UUID().uuidString), "title": .string("x"), "bogus": .bool(true)]))
        #expect(!unknownKey.ok)
        #expect(unknownKey.error?.contains("unknown parameter") == true)
    }

    // MARK: - Not-wired guard (engine nil)

    @Test("all four new chat commands fail actionably when the copilot engine isn't wired")
    func engineNotWired() async {
        let store = ProjectStore()
        let router = CommandRouter(store: store) // copilotEngine left nil.
        let someID = UUID().uuidString

        for (command, params) in [
            ("ai.copilotChats", [String: JSONValue]()),
            ("ai.copilotResumeChat", ["chatId": .string(someID)]),
            ("ai.copilotDeleteChat", ["chatId": .string(someID)]),
            ("ai.copilotRenameChat", ["chatId": .string(someID), "title": .string("x")]),
        ] {
            let response = await router.handle(ControlRequest(id: command, command: command, params: params))
            #expect(!response.ok, "\(command) should fail when unwired")
            #expect(response.error?.contains("not wired") == true, "\(command): \(response.error ?? "?")")
        }
    }

    // MARK: - ai.copilotReset additive fields (§6.5)

    @Test("ai.copilotReset response omits archivedChatId/evictedChatId when nothing was archived")
    func resetOmitsAdditiveFieldsWhenEmpty() async {
        let (router, _, engine) = makeWiredRouter()
        _ = engine // strong hold: router.copilotEngine is weak
        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotReset"))
        #expect(response.ok)
        #expect(response.result?["archivedChatId"] == nil)
        #expect(response.result?["evictedChatId"] == nil)
    }

    @Test("ai.copilotReset response carries archivedChatId when a conversation was archived")
    func resetCarriesArchivedChatId() async throws {
        let (router, store, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("done")], stopReason: .endTurn, provider: "fake"),
        ])
        _ = try engine.send("hello")
        await engine.waitForTurn()
        let chatID = engine.currentChatID

        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotReset"))
        #expect(response.ok)
        #expect(response.result?["archivedChatId"]?.stringValue == chatID.uuidString)
        #expect(response.result?["evictedChatId"] == nil)
        #expect(store.copilotChats.count == 1)
    }

    @Test("ai.copilotReset response carries evictedChatId when archiving pushed past the cap (§7.1, never silent)")
    func resetCarriesEvictedChatId() async throws {
        let (router, store, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("ok")], stopReason: .endTurn, provider: "fake"),
        ])
        var oldest: CopilotChatDocument?
        for index in 0..<CopilotChatLimits.maxArchivedChats {
            let chat = archivedChat(title: "old \(index)", updatedAt: 1_000 + TimeInterval(index))
            if index == 0 { oldest = chat }
            store.archiveCopilotChat(chat)
        }
        _ = try engine.send("the 21st conversation")
        await engine.waitForTurn()

        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotReset"))
        #expect(response.ok)
        #expect(response.result?["evictedChatId"]?.stringValue == oldest?.id.uuidString)
        #expect(store.copilotChats.count == CopilotChatLimits.maxArchivedChats)
    }

    // MARK: - ai.copilotState additive fields (§6.5)

    @Test("ai.copilotState carries chatId always; chatTitle/droppedEntries only once set/> 0")
    func stateCarriesChatFields() async throws {
        let (router, _, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("reply")], stopReason: .endTurn, provider: "fake"),
        ])
        let freshState = await router.handle(ControlRequest(id: "1", command: "ai.copilotState"))
        #expect(freshState.ok)
        #expect(freshState.result?["chatId"]?.stringValue == engine.currentChatID.uuidString)
        #expect(freshState.result?["chatTitle"] == nil) // not derived yet
        #expect(freshState.result?["droppedEntries"] == nil)
        // Existing fields untouched.
        #expect(freshState.result?["status"]?.stringValue == "idle")
        #expect(freshState.result?["transcript"]?.arrayValue?.isEmpty == true)

        _ = try engine.send("first message")
        await engine.waitForTurn()
        let afterSend = await router.handle(ControlRequest(id: "2", command: "ai.copilotState"))
        #expect(afterSend.result?["chatId"]?.stringValue == engine.currentChatID.uuidString)
        #expect(afterSend.result?["chatTitle"]?.stringValue == "first message")
    }

    @Test("ai.copilotState surfaces droppedEntries inherited from a resumed truncated chat")
    func stateCarriesInheritedDroppedEntries() async throws {
        let (router, store, engine) = makeWiredRouter()
        let chat = archivedChat(droppedEntries: 40)
        store.archiveCopilotChat(chat)
        try engine.resumeChat(id: chat.id)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotState"))
        #expect(response.result?["droppedEntries"]?.doubleValue == 40)
        #expect(response.result?["chatId"]?.stringValue == chat.id.uuidString)
        #expect(response.result?["chatTitle"]?.stringValue == chat.title)
    }
}
