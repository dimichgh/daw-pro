import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Chat-persist §5.3 mapping laws, tested pure (no engine, no provider):
/// L1 (thinking never persisted — no signature bytes on disk), L2 (all-thinking
/// assistant → placeholder, never dropped/empty), L3 (partials dropped on
/// snapshot), the §7 caps with L6 `droppedEntries` honesty, forward-tolerant
/// restore, and the `sanitizeProviderHistory` resume trust boundary.
@MainActor
@Suite("Copilot chat mapping (L1/L2/L3 + caps)")
struct CopilotChatMappingTests {
    // MARK: - Helpers

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func entry(
        _ kind: CopilotEngine.TranscriptEntry.Kind, turn: String = "t1", partial: Bool = false
    ) -> CopilotEngine.TranscriptEntry {
        CopilotEngine.TranscriptEntry(id: UUID(), turnID: turn, kind: kind, partial: partial)
    }

    private func snapshot(
        transcript: [CopilotEngine.TranscriptEntry] = [],
        history: [CopilotMessage] = [],
        id: UUID = UUID(),
        title: String? = "test chat",
        inheritedDropped: Int = 0
    ) -> CopilotChatDocument {
        CopilotChatMapping.snapshot(
            transcript: transcript, history: history, id: id, title: title,
            createdAt: date(100), updatedAt: date(200), model: "claude-sonnet-5",
            inheritedDropped: inheritedDropped)
    }

    /// A transcript of `turns` turns, `entriesPerTurn` assistant entries each.
    private func transcript(turns: Int, entriesPerTurn: Int, text: String = "line") -> [CopilotEngine.TranscriptEntry] {
        var entries: [CopilotEngine.TranscriptEntry] = []
        for turn in 0..<turns {
            for line in 0..<entriesPerTurn {
                entries.append(entry(.assistant("\(text) \(turn).\(line)"), turn: "turn-\(turn)"))
            }
        }
        return entries
    }

    // MARK: - L1: thinking never persisted

    @Test("L1: thinking blocks are stripped from persisted provider history — no thinking type, no signature bytes anywhere")
    func thinkingNeverPersisted() throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"secret reasoning","signature":"sig-SECRET-BYTES"}"#.utf8)
        let history: [CopilotMessage] = [
            CopilotMessage(role: .user, blocks: [.text("do the thing")]),
            CopilotMessage(role: .assistant, blocks: [
                .thinking(summary: "weighing options", rawJSON: thinkingJSON),
                .text("Done."),
            ]),
        ]
        let document = snapshot(
            transcript: [entry(.user("do the thing")), entry(.thinking("weighing options")), entry(.assistant("Done."))],
            history: history)

        #expect(!document.providerMessages.flatMap(\.blocks).contains { $0.type == "thinking" })
        // The assistant message survives with its visible text (L2 not needed here).
        #expect(document.providerMessages[1].blocks.map(\.type) == ["text"])
        // The thinking SUMMARY stays in the display transcript...
        #expect(document.transcript.contains { $0.kind == "thinking" && $0.text == "weighing options" })
        // ...but no signature/rawJSON byte ever reaches the encoded document.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(document), as: UTF8.self)
        #expect(!json.contains("sig-SECRET-BYTES"))
        #expect(!json.contains("secret reasoning"))
    }

    @Test("L2: an all-thinking assistant message persists as the placeholder text block — never dropped, never empty")
    func allThinkingAssistantBecomesPlaceholder() {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"...","signature":"s"}"#.utf8)
        let history: [CopilotMessage] = [
            CopilotMessage(role: .user, blocks: [.text("hm")]),
            CopilotMessage(role: .assistant, blocks: [.thinking(summary: "", rawJSON: thinkingJSON)]),
            CopilotMessage(role: .user, blocks: [.text("follow-up")]),
        ]
        let document = snapshot(transcript: [entry(.user("hm"))], history: history)

        // Alternation preserved: user / assistant / user — nothing dropped.
        #expect(document.providerMessages.map(\.role) == ["user", "assistant", "user"])
        let assistant = document.providerMessages[1]
        #expect(assistant.blocks.count == 1)
        #expect(assistant.blocks[0].type == "text")
        #expect(assistant.blocks[0].text == CopilotChatMapping.noVisibleOutputPlaceholder)
    }

    @Test("L3: partial (still-streaming) entries are dropped on snapshot and NOT counted into droppedEntries")
    func partialsDroppedOnSnapshot() {
        let document = snapshot(transcript: [
            entry(.user("go")),
            entry(.assistant("finished answer")),
            entry(.assistant("half an ans"), partial: true),
            entry(.thinking("still thin"), partial: true),
        ])
        #expect(document.transcript.count == 2)
        #expect(document.transcript.map(\.kind) == ["user", "assistant"])
        #expect(document.droppedEntries == nil)  // partials are not truncation (L6 counts caps only)
    }

    // MARK: - Caps (§7) + L6 honesty

    @Test("entry cap: oldest WHOLE turns are dropped (never half a turn) and counted into droppedEntries")
    func entryCapDropsOldestWholeTurns() {
        let cap = CopilotChatLimits.maxPersistedTranscriptEntries
        // 45 turns × 10 entries = 450 → five whole turns (50 entries) must go.
        let document = snapshot(transcript: transcript(turns: 45, entriesPerTurn: 10))
        #expect(document.transcript.count == cap)
        #expect(document.droppedEntries == 50)
        // The head is a TURN boundary: turn-5's first entry, not mid-turn.
        #expect(document.transcript.first?.turnId == "turn-5")
        #expect(document.transcript.last?.turnId == "turn-44")
    }

    @Test("droppedEntries accumulates on top of an inherited count from a previously truncated persist/resume")
    func inheritedDroppedAccumulates() {
        // 41 × 10 = 410 entries → one whole turn (10 entries) freshly dropped.
        let document = snapshot(
            transcript: transcript(turns: 41, entriesPerTurn: 10),
            inheritedDropped: 40)
        #expect(document.droppedEntries == 50)  // 40 inherited + 10 fresh
    }

    @Test("byte cap: oldest provider EXCHANGES are dropped first (uncounted, min 1 kept), then oldest transcript turns (counted)")
    func byteCapDropsProviderExchangesFirst() {
        // Two fat exchanges (~150 KiB each) + a tiny transcript: dropping the
        // OLDEST exchange alone brings the chat under 256 KiB, so the
        // transcript must survive untouched and droppedEntries stay nil.
        let fat = String(repeating: "x", count: 150 * 1024)
        let history: [CopilotMessage] = [
            CopilotMessage(role: .user, blocks: [.text("first ask")]),
            CopilotMessage(role: .assistant, blocks: [.text(fat)]),
            CopilotMessage(role: .user, blocks: [.text("second ask")]),
            CopilotMessage(role: .assistant, blocks: [.text(fat)]),
        ]
        let document = snapshot(
            transcript: [entry(.user("first ask")), entry(.assistant("ok"))],
            history: history)

        #expect(document.providerMessages.count == 2)
        #expect(document.providerMessages.first?.blocks.first?.text == "second ask")  // the OLDEST exchange went
        #expect(document.transcript.count == 2)
        #expect(document.droppedEntries == nil)
    }

    @Test("byte cap: once one exchange remains, oldest transcript TURNS are dropped and counted — the last turn always survives")
    func byteCapFallsBackToTranscriptTurns() {
        let fat = String(repeating: "y", count: 150 * 1024)
        let document = snapshot(
            transcript: [
                entry(.user("old ask"), turn: "t1"),
                entry(.assistant(fat), turn: "t1"),
                entry(.user("new ask"), turn: "t2"),
                entry(.assistant(fat), turn: "t2"),
            ],
            history: [CopilotMessage(role: .user, blocks: [.text("only exchange")])])

        // t1 (2 entries) dropped; t2 survives even though the chat may still
        // exceed the SOFT cap (the last turn is never destroyed).
        #expect(document.transcript.map(\.turnId) == ["t2", "t2"])
        #expect(document.droppedEntries == 2)
        #expect(document.providerMessages.count == 1)  // min 1 exchange kept
    }

    // MARK: - Restore (forward tolerance)

    @Test("restore maps every known kind back, always partial:false; unknown kinds/types are skipped and counted")
    func restoreMapsAndSkips() {
        let document = CopilotChatDocument(
            id: UUID(), title: "restore me", createdAt: date(1), updatedAt: date(2),
            transcript: [
                .init(turnId: "t1", kind: "user", text: "hi"),
                .init(turnId: "t1", kind: "assistant", text: "hello"),
                .init(turnId: "t1", kind: "thinking", text: "hmm"),
                .init(turnId: "t1", kind: "toolCall", command: "track.add", summary: "{}"),
                .init(turnId: "t1", kind: "toolResult", command: "track.add", ok: true, summary: "{}"),
                .init(turnId: "t1", kind: "failure", text: "cancelled"),
                .init(turnId: "t1", kind: "hologram", text: "from the future"),  // unknown kind
                .init(turnId: "t1", kind: "user"),                               // user without text
            ],
            providerMessages: [
                .init(role: "user", blocks: [.init(type: "text", text: "hi")]),
                .init(role: "assistant", blocks: [
                    .init(type: "toolUse", toolUseId: "c1", name: "track_add", inputJSON: #"{"name":"T"}"#),
                    .init(type: "quantum", text: "unknown block type"),          // unknown type
                ]),
                .init(role: "user", blocks: [
                    .init(type: "toolResult", toolUseId: "c1", content: "ok", isError: true),
                ]),
                .init(role: "narrator", blocks: []),                              // unknown role
            ])

        let restored = CopilotChatMapping.restore(document)
        #expect(restored.transcript.count == 6)
        #expect(restored.transcript.allSatisfy { !$0.partial })
        #expect(restored.skippedEntries == 4)  // hologram + textless user + quantum block + narrator

        #expect(restored.history.count == 3)
        guard case .toolUse(let id, let name, let inputJSON) = restored.history[1].blocks.first else {
            Issue.record("expected a restored toolUse block"); return
        }
        #expect(id == "c1")
        #expect(name == "track_add")
        #expect(String(decoding: inputJSON, as: UTF8.self) == #"{"name":"T"}"#)
        guard case .toolResult(_, let content, let isError) = restored.history[2].blocks.first else {
            Issue.record("expected a restored toolResult block"); return
        }
        #expect(content == "ok")
        #expect(isError)
    }

    @Test("snapshot → restore round-trips the visible conversation")
    func snapshotRestoreRoundTrip() {
        let transcript = [
            entry(.user("add drums")),
            entry(.toolCall(command: "track.add", argsSummary: #"{"name":"Drums"}"#)),
            entry(.toolResult(command: "track.add", ok: true, summary: "{}")),
            entry(.assistant("Added.")),
        ]
        let history = [
            CopilotMessage(role: .user, blocks: [.text("add drums")]),
            CopilotMessage(role: .assistant, blocks: [.text("Added.")]),
        ]
        let document = snapshot(transcript: transcript, history: history)
        let restored = CopilotChatMapping.restore(document)

        #expect(restored.skippedEntries == 0)
        #expect(restored.transcript.map(\.id) == transcript.map(\.id))
        #expect(restored.history == history)
        #expect(CopilotChatMapping.sanitizeProviderHistory(restored.history) == history)
    }

    // MARK: - sanitizeProviderHistory (§5.3 trust boundary)

    @Test("sanitize drops leading messages until the head is a plain user text message")
    func sanitizeFixesBadHead() {
        let messages = [
            CopilotMessage(role: .assistant, blocks: [.text("orphaned reply")]),
            CopilotMessage(role: .user, blocks: [.toolResult(id: "x", content: "stale", isError: false)]),
            CopilotMessage(role: .user, blocks: [.text("real ask")]),
            CopilotMessage(role: .assistant, blocks: [.text("real answer")]),
        ]
        let sanitized = CopilotChatMapping.sanitizeProviderHistory(messages)
        #expect(sanitized.count == 2)
        guard case .text(let headText) = sanitized[0].blocks.first else {
            Issue.record("head should be plain text"); return
        }
        #expect(headText == "real ask")
    }

    @Test("sanitize returns [] for a toolResult whose id has no toolUse in the immediately preceding assistant message")
    func sanitizeRejectsBrokenPairing() {
        let broken = [
            CopilotMessage(role: .user, blocks: [.text("ask")]),
            CopilotMessage(role: .assistant, blocks: [
                .toolUse(id: "call_A", name: "track_add", inputJSON: Data("{}".utf8)),
            ]),
            CopilotMessage(role: .user, blocks: [
                .toolResult(id: "call_MISMATCH", content: "?", isError: false),
            ]),
        ]
        #expect(CopilotChatMapping.sanitizeProviderHistory(broken).isEmpty)
    }

    @Test("sanitize keeps a correctly paired tool round intact")
    func sanitizeKeepsGoodPairing() {
        let good = [
            CopilotMessage(role: .user, blocks: [.text("ask")]),
            CopilotMessage(role: .assistant, blocks: [
                .text("using a tool"),
                .toolUse(id: "call_A", name: "track_add", inputJSON: Data("{}".utf8)),
            ]),
            CopilotMessage(role: .user, blocks: [
                .toolResult(id: "call_A", content: "ok", isError: false),
            ]),
            CopilotMessage(role: .assistant, blocks: [.text("done")]),
        ]
        #expect(CopilotChatMapping.sanitizeProviderHistory(good) == good)
    }

    @Test("sanitize of an entirely unusable history returns [] (display transcript survives elsewhere)")
    func sanitizeAllBadReturnsEmpty() {
        let unusable = [
            CopilotMessage(role: .assistant, blocks: [.text("only assistant talk")]),
            CopilotMessage(role: .assistant, blocks: [.text("still no user head")]),
        ]
        #expect(CopilotChatMapping.sanitizeProviderHistory(unusable).isEmpty)
    }

    // MARK: - Title derivation

    @Test("deriveTitle flattens newlines, trims, caps at 60 chars, and returns nil for whitespace")
    func deriveTitle() {
        #expect(CopilotChatMapping.deriveTitle(from: "  add a bass\nline  ") == "add a bass line")
        #expect(CopilotChatMapping.deriveTitle(from: "   \n  ") == nil)
        let long = String(repeating: "t", count: 200)
        #expect(CopilotChatMapping.deriveTitle(from: long)?.count == CopilotChatLimits.derivedTitleLength)
    }

    @Test("snapshot falls back to deriving the title from the first user entry, else 'New chat'")
    func snapshotTitleFallback() {
        let derived = snapshot(transcript: [entry(.user("make it swing"))], title: nil)
        #expect(derived.title == "make it swing")
        let untitled = snapshot(transcript: [entry(.assistant("hello"))], title: nil)
        #expect(untitled.title == "New chat")
    }
}
