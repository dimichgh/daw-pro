// CopilotChatMapping.swift
// DAWControl
//
// Pure static mapping between the copilot engine's live conversation state
// (transcript + provider history) and the persisted `CopilotChatDocument`
// (docs/research/design-copilot-chat-persistence.md §5.3). Unit-testable
// without an engine. The three load-bearing laws enforced here:
//
//  L1 — persisted provider history NEVER contains thinking blocks (their
//       signatures may not validate after a model switch; `rawJSON` never
//       round-trips to disk).
//  L2 — an assistant message left with zero blocks after the strip is
//       REPLACED by a text placeholder, never dropped (alternation safety
//       with the pinned anthropic-version), never left empty (Anthropic
//       400s on empty content).
//  L3 — `partial == true` transcript entries are DROPPED on snapshot:
//       partials are finalized only by the turn loop, never by the
//       persistence path, so a persisted chat always reads as a consistent,
//       completed prefix of the conversation.

import AIServices
import DAWCore
import Foundation

@MainActor
enum CopilotChatMapping {
    /// The L2 placeholder — also what the engine's turn-end strip installs,
    /// so in-memory history between turns ≡ persisted shape.
    static let noVisibleOutputPlaceholder = "(the model produced no visible output this turn)"

    // MARK: - Snapshot (engine → document)

    /// Builds the persisted document for one conversation: drops partials
    /// (L3), maps entry kinds to their string-typed disk twins, strips
    /// thinking from provider history (L1, with the L2 placeholder), then
    /// applies the §7 caps, accumulating cap-drops into `droppedEntries` on
    /// top of any `inheritedDropped` from a previously truncated
    /// persist/resume (L6).
    static func snapshot(
        transcript: [CopilotEngine.TranscriptEntry],
        history: [CopilotMessage],
        id: UUID,
        title: String?,
        createdAt: Date,
        updatedAt: Date,
        model: String?,
        inheritedDropped: Int
    ) -> CopilotChatDocument {
        // L3 — finalize-or-drop: a snapshot taken mid-stream keeps only what
        // the turn loop finalized.
        let finalized = transcript.filter { !$0.partial }
        var entries = finalized.map(entry(from:))
        var dropped = 0

        // §7.2 — per-chat transcript cap: drop the OLDEST WHOLE TURNS
        // (contiguous turnId groups — a turn is never half-shown) until
        // under. The last remaining turn always survives, even over-cap
        // (soft): dropping it would empty the chat.
        while entries.count > CopilotChatLimits.maxPersistedTranscriptEntries,
              let removed = droppingOldestTurn(&entries) {
            dropped += removed
        }

        var document = CopilotChatDocument(
            id: id,
            title: resolvedTitle(title, finalized: finalized),
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            droppedEntries: nil,
            transcript: entries,
            providerMessages: history.map(providerMessage(from:))
        )
        document.droppedEntries = honestCount(inheritedDropped + dropped)

        // §7.3 — per-chat byte soft cap (256 KiB on the encoded chat): first
        // drop oldest provider EXCHANGES (min 1 kept — provider trims reduce
        // only the model's memory, which already lives with `trimHistory`,
        // so they are NOT counted into droppedEntries), then oldest
        // transcript turns (counted, L6).
        let encoder = JSONEncoder()
        while let bytes = try? encoder.encode(document),
              bytes.count > CopilotChatLimits.maxPersistedChatBytes {
            if let trimmed = droppingOldestProviderExchange(document.providerMessages) {
                document.providerMessages = trimmed
                continue
            }
            if let removed = droppingOldestTurn(&document.transcript) {
                dropped += removed
                document.droppedEntries = honestCount(inheritedDropped + dropped)
                continue
            }
            break  // one turn + one exchange left — soft cap, stop honestly
        }
        return document
    }

    /// Derives a chat title from the first user message (≤
    /// `derivedTitleLength`, newlines flattened); nil for whitespace-only
    /// input. Shared by the engine's first-`send()` derivation and the
    /// snapshot fallback below.
    static func deriveTitle(from message: String) -> String? {
        let flattened = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(CopilotChatLimits.derivedTitleLength))
    }

    // MARK: - Restore (document → engine)

    /// Rebuilds live engine state from a persisted chat. Unknown `kind`/
    /// `type` strings (a FUTURE build's vocabulary, or hand-edits) are
    /// skipped and counted (forward tolerance, L6); restored entries are
    /// always `partial: false`. The returned history is RAW — callers pass
    /// it through `sanitizeProviderHistory` before trusting it.
    static func restore(
        _ document: CopilotChatDocument
    ) -> (transcript: [CopilotEngine.TranscriptEntry], history: [CopilotMessage], skippedEntries: Int) {
        var skipped = 0
        var transcript: [CopilotEngine.TranscriptEntry] = []
        for entry in document.transcript {
            guard let kind = transcriptKind(entry) else {
                skipped += 1
                continue
            }
            transcript.append(CopilotEngine.TranscriptEntry(
                id: entry.id, turnID: entry.turnId, kind: kind, partial: false))
        }

        var history: [CopilotMessage] = []
        for message in document.providerMessages {
            guard let role = CopilotMessage.Role(rawValue: message.role) else {
                skipped += 1
                continue
            }
            var blocks: [CopilotContentBlock] = []
            for block in message.blocks {
                switch block.type {
                case "text":
                    blocks.append(.text(block.text ?? ""))
                case "toolUse":
                    blocks.append(.toolUse(
                        id: block.toolUseId ?? "", name: block.name ?? "",
                        inputJSON: Data((block.inputJSON ?? "{}").utf8)))
                case "toolResult":
                    blocks.append(.toolResult(
                        id: block.toolUseId ?? "", content: block.content ?? "",
                        isError: block.isError ?? false))
                default:
                    // Includes "thinking", which L1 forbids on disk — a
                    // hand-edited block is dropped, never replayed.
                    skipped += 1
                }
            }
            history.append(CopilotMessage(role: role, blocks: blocks))
        }
        return (transcript, history, skipped)
    }

    /// Resume trust boundary (§5.3) for hand-edited/corrupt files:
    ///  1. drops leading messages until the head is a plain user TEXT
    ///     message (the `trimHistory` invariant);
    ///  2. verifies every `toolResult` id pairs with a `toolUse` in the
    ///     IMMEDIATELY preceding assistant message, else returns `[]` — the
    ///     display transcript survives and the conversation continues with
    ///     fresh provider context (honest and safe, never a guaranteed 400
    ///     loop).
    static func sanitizeProviderHistory(_ messages: [CopilotMessage]) -> [CopilotMessage] {
        var sanitized = messages
        while let head = sanitized.first, !isPlainUserTextMessage(head) {
            sanitized.removeFirst()
        }
        for index in sanitized.indices {
            let resultIDs = toolResultIDs(sanitized[index])
            guard !resultIDs.isEmpty else { continue }
            guard index > 0, sanitized[index - 1].role == .assistant,
                  resultIDs.isSubset(of: toolUseIDs(sanitized[index - 1]))
            else { return [] }
        }
        return sanitized
    }

    // MARK: - Private mapping details

    private static func entry(from transcriptEntry: CopilotEngine.TranscriptEntry) -> CopilotChatDocument.Entry {
        var entry = CopilotChatDocument.Entry(
            id: transcriptEntry.id, turnId: transcriptEntry.turnID, kind: "user")
        switch transcriptEntry.kind {
        case .user(let text):
            entry.kind = "user"; entry.text = text
        case .assistant(let text):
            entry.kind = "assistant"; entry.text = text
        case .thinking(let text):
            // The thinking SUMMARY stays for display — only the provider-side
            // block (signature and all) is stripped, per L1.
            entry.kind = "thinking"; entry.text = text
        case .toolCall(let command, let argsSummary):
            entry.kind = "toolCall"; entry.command = command; entry.summary = argsSummary
        case .toolResult(let command, let ok, let summary):
            entry.kind = "toolResult"; entry.command = command; entry.ok = ok; entry.summary = summary
        case .failure(let text):
            entry.kind = "failure"; entry.text = text
        }
        return entry
    }

    private static func transcriptKind(_ entry: CopilotChatDocument.Entry) -> CopilotEngine.TranscriptEntry.Kind? {
        switch entry.kind {
        case "user": return entry.text.map { .user($0) }
        case "assistant": return entry.text.map { .assistant($0) }
        case "thinking": return entry.text.map { .thinking($0) }
        case "failure": return entry.text.map { .failure($0) }
        case "toolCall":
            guard let command = entry.command else { return nil }
            return .toolCall(command: command, argsSummary: entry.summary ?? "")
        case "toolResult":
            guard let command = entry.command else { return nil }
            return .toolResult(command: command, ok: entry.ok ?? false, summary: entry.summary ?? "")
        default:
            return nil  // forward tolerance — skipped and counted by restore
        }
    }

    private static func providerMessage(from message: CopilotMessage) -> CopilotChatDocument.ProviderMessage {
        var blocks: [CopilotChatDocument.ProviderMessage.Block] = []
        for block in message.blocks {
            switch block {
            case .text(let text):
                blocks.append(.init(type: "text", text: text))
            case .toolUse(let id, let name, let inputJSON):
                blocks.append(.init(
                    type: "toolUse", toolUseId: id, name: name,
                    inputJSON: String(decoding: inputJSON, as: UTF8.self)))
            case .toolResult(let id, let content, let isError):
                // isError rides the wire house rule (absent-not-false).
                blocks.append(.init(
                    type: "toolResult", toolUseId: id, content: content,
                    isError: isError ? true : nil))
            case .thinking:
                continue  // L1 — never persisted, summary already in transcript
            }
        }
        if blocks.isEmpty, message.role == .assistant {
            // L2 — never dropped (alternation safety), never empty.
            blocks = [.init(type: "text", text: noVisibleOutputPlaceholder)]
        }
        return .init(role: message.role == .user ? "user" : "assistant", blocks: blocks)
    }

    /// Removes the leading contiguous turnId group from `entries` and
    /// returns how many entries went — or nil when only one turn remains
    /// (the last turn is never dropped).
    private static func droppingOldestTurn(_ entries: inout [CopilotChatDocument.Entry]) -> Int? {
        guard let firstTurn = entries.first?.turnId,
              entries.contains(where: { $0.turnId != firstTurn })
        else { return nil }
        let count = entries.prefix(while: { $0.turnId == firstTurn }).count
        entries.removeFirst(count)
        return count
    }

    /// Drops the oldest provider EXCHANGE (the `trimHistory` boundary law:
    /// an exchange starts at a plain user text message); nil when ≤ 1
    /// exchange remains (min 1 kept).
    private static func droppingOldestProviderExchange(
        _ messages: [CopilotChatDocument.ProviderMessage]
    ) -> [CopilotChatDocument.ProviderMessage]? {
        let starts = messages.indices.filter { index in
            messages[index].role == "user"
                && !messages[index].blocks.contains { $0.type == "toolResult" }
        }
        guard starts.count > 1 else { return nil }
        return Array(messages.dropFirst(starts[1]))
    }

    private static func resolvedTitle(
        _ title: String?, finalized: [CopilotEngine.TranscriptEntry]
    ) -> String {
        if let title, !title.isEmpty {
            return String(title.prefix(CopilotChatLimits.maxTitleLength))
        }
        for entry in finalized {
            if case .user(let text) = entry.kind, let derived = deriveTitle(from: text) {
                return derived
            }
        }
        return "New chat"
    }

    private static func honestCount(_ total: Int) -> Int? {
        total > 0 ? total : nil  // L6: omit when 0 — never a noisy zero
    }

    private static func isPlainUserTextMessage(_ message: CopilotMessage) -> Bool {
        guard message.role == .user, !message.blocks.isEmpty else { return false }
        var sawText = false
        for block in message.blocks {
            if case .toolResult = block { return false }
            if case .text = block { sawText = true }
        }
        return sawText
    }

    private static func toolResultIDs(_ message: CopilotMessage) -> Set<String> {
        var ids: Set<String> = []
        for block in message.blocks {
            if case .toolResult(let id, _, _) = block { ids.insert(id) }
        }
        return ids
    }

    private static func toolUseIDs(_ message: CopilotMessage) -> Set<String> {
        var ids: Set<String> = []
        for block in message.blocks {
            if case .toolUse(let id, _, _) = block { ids.insert(id) }
        }
        return ids
    }
}
