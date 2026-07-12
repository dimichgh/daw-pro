// CopilotEngine.swift
// DAWControl
//
// The in-app AI Copilot's turn loop (M6 rail-c; see
// docs/research/design-rail-a-copilot.md §2/§4/§5/§11). Drives a tool-calling
// conversation against whichever `CopilotProviding` is resolved per turn,
// executing tool calls IN-PROCESS through the exact same `CommandRouter`
// path the control-protocol WebSocket uses (no loopback self-connection).
//
// Lives in DAWControl, not AIServices: it holds `CommandRouter`/`JSONValue`
// (DAWControl types) and DAWControl already depends on AIServices
// (Package.swift), so the reverse placement would be a dependency cycle.
// `@MainActor @Observable` so DAWApp views can observe it directly.

import AIServices
import DAWCore
import Foundation
import Observation

@MainActor
@Observable
public final class CopilotEngine {
    public enum TurnStatus: String, Sendable {
        case idle, running, done, failed, cancelled
    }

    /// One line of the copilot's transcript — the UI/state surface
    /// (`ai.copilotState` wire shape mirrors this; see `stateJSON(turnID:)`).
    public struct TranscriptEntry: Identifiable, Sendable {
        public enum Kind: Sendable {
            case user(String)
            case assistant(String)
            case toolCall(command: String, argsSummary: String)
            case toolResult(command: String, ok: Bool, summary: String)
            /// Provider/turn-level error, actionable text (never key material).
            case failure(String)
        }
        public let id: UUID
        public let turnID: String
        public let kind: Kind
    }

    // MARK: - Public state

    public private(set) var transcript: [TranscriptEntry] = []
    public private(set) var status: TurnStatus = .idle
    public private(set) var currentTurnID: String?

    // MARK: - Configuration

    private let store: ProjectStore
    private let dispatch: @MainActor (ControlRequest) async -> ControlResponse
    private let providerFactory: (@MainActor () throws -> any CopilotProviding)?
    private let catalog: [CopilotTool]
    private let catalogByCommand: [String: CopilotTool]
    /// Resolves the per-turn tool-round budget (beta m10-m). A closure, not a stored
    /// Int, so a live user setting (Settings → Copilot) is read FRESH at the start of
    /// each turn without live-patching the engine — the bootstrap injects
    /// `{ copilotLimitsStore.maxRounds }`. `@MainActor`, matching the engine's own
    /// isolation and its `dispatch`/`provider` closures (this reads a @MainActor
    /// store, and every `send`/`runTurn` runs on the main actor per rail-a), rather
    /// than a `@Sendable` closure that couldn't touch that store.
    private let maxToolRoundsResolver: @MainActor () -> Int
    private let historyLimit: Int

    /// Provider-facing conversation history (trimmed; see `trimHistory()`).
    /// Distinct from `transcript`, which is the unbounded UI surface.
    private var history: [CopilotMessage] = []
    private var turnTask: Task<Void, Never>?

    public init(
        store: ProjectStore,
        dispatch: @escaping @MainActor (ControlRequest) async -> ControlResponse,
        provider: (@MainActor () throws -> any CopilotProviding)? = nil,
        catalog: [CopilotTool] = CopilotToolCatalog.v1,
        maxToolRounds: @escaping @MainActor () -> Int = { CopilotLimits.defaultMaxRounds },
        historyLimit: Int = 20
    ) {
        self.store = store
        self.dispatch = dispatch
        self.providerFactory = provider
        self.catalog = catalog
        self.catalogByCommand = Dictionary(uniqueKeysWithValues: catalog.map { ($0.command, $0) })
        self.maxToolRoundsResolver = maxToolRounds
        self.historyLimit = historyLimit
    }

    // MARK: - Public API

    /// Starts a new turn. Synchronous so `ai.copilotSend` can fail fast:
    /// throws immediately if a turn is already running, or if no AI provider
    /// is configured (the actionable, key-free `noProviderConfigured`
    /// message, naming Settings ⌘,). Returns the new turn's id; the turn then
    /// runs asynchronously — poll `stateJSON(turnID:)` or await
    /// `waitForTurn()`.
    @discardableResult
    public func send(_ message: String, maxRoundsOverride: Int? = nil) throws -> String {
        guard status != .running else {
            throw ControlError("a copilot turn is already running — poll ai.copilotState, or ai.copilotReset")
        }
        // Resolve NOW, on the calling stack, so a missing key surfaces
        // synchronously from `send` rather than only showing up later in
        // `ai.copilotState` — same "fail fast" contract as ai.copilotSend's
        // wire doc (§6).
        let resolvedProvider = try resolveProvider()

        // Resolve the per-turn round budget ONCE, here on the calling stack (beta
        // m10-m), and hand the fixed value to `runTurn` — so a mid-turn settings
        // change (or a resolver read on a later poll) can never tear a running turn.
        // A caller-supplied override outranks the resolver for THIS turn only; both
        // are clamped into `CopilotLimits.validRange` (an override of 0 → 1, 99 → 32),
        // since a caller bounding its own budget only ever harms itself.
        let effectiveMaxRounds = CopilotLimits.clamp(maxRoundsOverride ?? maxToolRoundsResolver())

        let turnID = UUID().uuidString
        currentTurnID = turnID
        status = .running
        appendTranscript(turnID: turnID, .user(message))
        history.append(CopilotMessage(role: .user, blocks: [.text(message)]))
        trimHistory()

        turnTask = Task { [weak self] in
            await self?.runTurn(turnID: turnID, provider: resolvedProvider, maxRounds: effectiveMaxRounds)
        }
        return turnID
    }

    /// Requests cancellation of the in-flight turn. Takes effect at the next
    /// round boundary (i.e. inside the provider's network await, or before
    /// the next tool-round starts) — an in-flight command dispatch is never
    /// interrupted mid-edit.
    public func cancel() {
        turnTask?.cancel()
    }

    /// Cancels any in-flight turn and clears all state back to `.idle`.
    public func reset() {
        turnTask?.cancel()
        turnTask = nil
        transcript = []
        history = []
        currentTurnID = nil
        status = .idle
    }

    /// Awaits the stored turn `Task`, for deterministic test/rail-d
    /// completion without polling. A no-op if no turn has ever run.
    public func waitForTurn() async {
        await turnTask?.value
    }

    /// The `ai.copilotState` payload. `turnID == nil` returns the whole
    /// session's transcript; a non-nil `turnID` filters to that turn's
    /// entries — including an UNKNOWN turnId, which simply filters to an
    /// empty transcript (poller-friendly, not an error) while `status` and
    /// `currentTurnId` still report the engine's actual current turn.
    public func stateJSON(turnID: String?) -> JSONValue {
        let entries = turnID.map { id in transcript.filter { $0.turnID == id } } ?? transcript
        var object: [String: JSONValue] = [
            "status": .string(status.rawValue),
            "transcript": .array(entries.map(Self.entryJSON)),
            // Additive limits echo (beta m10-m): the effective per-turn round budget
            // the engine would honor RIGHT NOW (the resolver value, clamped — an
            // `ai.copilotSend` override is per-turn and never reflected here) plus the
            // fixed default and valid bounds, so a client/agent can surface and
            // respect the same policy the Settings field edits.
            "limits": Self.limitsJSON(effectiveMaxRounds: CopilotLimits.clamp(maxToolRoundsResolver())),
        ]
        if let currentTurnID {
            object["currentTurnId"] = .string(currentTurnID)
        }
        return .object(object)
    }

    /// The `limits` sub-object shape (beta m10-m). `maxRounds` is the currently
    /// effective resolver value; `defaultMaxRounds`/`validMin`/`validMax` are the
    /// fixed `CopilotLimits` policy so a client needn't hardcode them.
    private static func limitsJSON(effectiveMaxRounds: Int) -> JSONValue {
        .object([
            "maxRounds": .number(Double(effectiveMaxRounds)),
            "defaultMaxRounds": .number(Double(CopilotLimits.defaultMaxRounds)),
            "validMin": .number(Double(CopilotLimits.validRange.lowerBound)),
            "validMax": .number(Double(CopilotLimits.validRange.upperBound)),
        ])
    }

    // MARK: - Capture seeding (rail-d; debug-tier only)

    /// Replaces the transcript + status wholesale for a deterministic capture or
    /// E2E, WITHOUT running a provider turn — the `debug.copilotSeed` hook (the
    /// ClipFix `setCardsForCapture` precedent). Not part of the turn loop: the
    /// real `send()`/`runTurn()` path is untouched, and any in-flight turn is
    /// cancelled first so the seeded state can't be clobbered by a landing round.
    /// Gated to the debug-tier command surface at the call site (off allCommands,
    /// off MCP) — never a provider call, never key material.
    public func seedForCapture(turnID: String, status: TurnStatus, entries: [TranscriptEntry.Kind]) {
        turnTask?.cancel()
        turnTask = nil
        transcript = entries.map { TranscriptEntry(id: UUID(), turnID: turnID, kind: $0) }
        self.status = status
        currentTurnID = status == .idle ? nil : turnID
    }

    // MARK: - Turn loop (§5)

    private func runTurn(turnID: String, provider: any CopilotProviding, maxRounds: Int) async {
        do {
            for round in 0..<maxRounds {
                // Rebuilt EVERY round: mid-turn tool calls mutate the
                // project, and the model must see the results.
                let (contextText, idMap) = Self.buildContext(store: store)
                let request = CopilotTurnRequest(
                    system: Self.systemPrompt + "\n\n" + contextText,
                    messages: history,
                    tools: catalog.map { $0.spec() },
                    maxTokens: 4096
                )
                let reply = try await provider.complete(request)
                try Task.checkCancellation()

                var toolUses: [(id: String, name: String, inputJSON: Data)] = []
                for block in reply.blocks {
                    switch block {
                    case .text(let text):
                        appendTranscript(turnID: turnID, .assistant(text))
                    case .toolUse(let id, let name, let inputJSON):
                        toolUses.append((id, name, inputJSON))
                        appendTranscript(turnID: turnID, .toolCall(
                            command: CopilotTool.command(fromToolName: name),
                            argsSummary: Self.summarize(inputJSON, limit: 300)))
                    case .toolResult:
                        // Providers never emit tool_result in a reply; ignore defensively.
                        continue
                    }
                }
                history.append(CopilotMessage(role: .assistant, blocks: reply.blocks))

                // Trust the BLOCKS over `stopReason` (§11.3): a reply with
                // tool_use blocks always executes them, even if stopReason
                // claimed endTurn.
                if toolUses.isEmpty {
                    if reply.blocks.isEmpty {
                        // §11.2: zero blocks -> done with a synthetic entry, never loop.
                        appendTranscript(turnID: turnID, .assistant("(no response)"))
                    }
                    status = .done
                    return
                }

                // §11.4: multiple tool_use blocks execute SEQUENTIALLY, in
                // order, with ALL results landing in one following user message.
                var resultBlocks: [CopilotContentBlock] = []
                for (index, call) in toolUses.enumerated() {
                    let command = CopilotTool.command(fromToolName: call.name)
                    guard let tool = catalogByCommand[command] else {
                        let message = "unknown tool \(call.name)"
                        resultBlocks.append(.toolResult(id: call.id, content: message, isError: true))
                        appendTranscript(turnID: turnID, .toolResult(command: command, ok: false, summary: message))
                        continue
                    }
                    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: call.inputJSON),
                          case .object(let inputParams) = decoded
                    else {
                        let message = "invalid arguments for \(call.name) — expected a JSON object"
                        resultBlocks.append(.toolResult(id: call.id, content: message, isError: true))
                        appendTranscript(turnID: turnID, .toolResult(command: command, ok: false, summary: message))
                        continue
                    }
                    _ = tool // catalog membership already confirmed; schema not re-validated here (the router validates).
                    let expandedParams = Self.expandIDs(inputParams, idMap: idMap)
                    let controlRequest = ControlRequest(
                        id: "copilot-\(turnID)-r\(round)-\(index)",
                        command: command,
                        params: expandedParams
                    )
                    let response = await dispatch(controlRequest)
                    if response.ok {
                        let encoded = Self.capResult(Self.encodedResultString(response.result), limit: 4000)
                        resultBlocks.append(.toolResult(id: call.id, content: encoded, isError: false))
                        appendTranscript(turnID: turnID, .toolResult(
                            command: command, ok: true, summary: Self.capResult(encoded, limit: 300)))
                    } else {
                        // Command errors go BACK TO THE MODEL as tool results
                        // (already agent-actionable) — they never abort the turn.
                        let message = response.error ?? "command failed"
                        resultBlocks.append(.toolResult(id: call.id, content: message, isError: true))
                        appendTranscript(turnID: turnID, .toolResult(command: command, ok: false, summary: message))
                    }
                }
                history.append(CopilotMessage(role: .user, blocks: resultBlocks))
                trimHistory()
            }

            // Rounds exhausted while the model still wants tools: work done
            // so far is real (each step is its own undo entry), not a failure.
            appendTranscript(turnID: turnID, .failure(
                "tool-round limit (\(maxRounds)) reached — partial work applied "
                + "(each step is undoable); send a follow-up to continue"))
            status = .done
        } catch is CancellationError {
            status = .cancelled
            appendTranscript(turnID: turnID, .failure("cancelled"))
        } catch {
            // AIServiceError (and friends) are already key-free/actionable.
            status = .failed
            appendTranscript(turnID: turnID, .failure(error.localizedDescription))
        }
    }

    // MARK: - Provider resolution

    private func resolveProvider() throws -> any CopilotProviding {
        if let providerFactory {
            return try providerFactory()
        }
        return try resolveCopilotProvider(environment: ProcessInfo.processInfo.environment, store: KeychainKeyStore())
    }

    // MARK: - History trimming

    /// Keeps the last `historyLimit` messages, trimmed only at EXCHANGE
    /// boundaries: an exchange starts at a plain user text message (never a
    /// user message made only of tool-result blocks) and runs through every
    /// following assistant/tool-result pair. Drops the oldest whole exchange
    /// repeatedly until under the limit or only one exchange remains — the
    /// head of `history` is always a plain user text message, and a
    /// tool_use/tool_result pair is never split (Anthropic 400s otherwise).
    private func trimHistory() {
        guard history.count > historyLimit else { return }
        var exchangeStarts = history.indices.filter(isExchangeStart)
        while history.count > historyLimit, exchangeStarts.count > 1 {
            let dropCount = exchangeStarts[1]
            history.removeFirst(dropCount)
            exchangeStarts = exchangeStarts.dropFirst().map { $0 - dropCount }
        }
    }

    private func isExchangeStart(_ index: Int) -> Bool {
        let message = history[index]
        guard case .user = message.role else { return false }
        return !message.blocks.contains { block in
            if case .toolResult = block { return true }
            return false
        }
    }

    // MARK: - Transcript

    private func appendTranscript(turnID: String, _ kind: TranscriptEntry.Kind) {
        transcript.append(TranscriptEntry(id: UUID(), turnID: turnID, kind: kind))
    }

    private static func entryJSON(_ entry: TranscriptEntry) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(entry.id.uuidString),
            "turnId": .string(entry.turnID),
        ]
        switch entry.kind {
        case .user(let text):
            object["kind"] = .string("user")
            object["text"] = .string(text)
        case .assistant(let text):
            object["kind"] = .string("assistant")
            object["text"] = .string(text)
        case .toolCall(let command, let argsSummary):
            object["kind"] = .string("toolCall")
            object["command"] = .string(command)
            object["summary"] = .string(argsSummary)
        case .toolResult(let command, let ok, let summary):
            object["kind"] = .string("toolResult")
            object["command"] = .string(command)
            object["ok"] = .bool(ok)
            object["summary"] = .string(summary)
        case .failure(let text):
            object["kind"] = .string("failure")
            object["text"] = .string(text)
        }
        return .object(object)
    }

    // MARK: - Fixed system prompt

    private static let systemPrompt = """
    You are the copilot inside DAW Pro, operating the currently running project through tools. \
    All positions and durations are in BEATS (quarter notes), never seconds, unless a tool \
    explicitly asks for seconds (e.g. an audio-file offset or a repaint window). Every tool call \
    you make is an undoable edit — the human can step back through your actions one at a time \
    with edit.undo. You do NOT have tools for destructive or global actions (deleting tracks, \
    opening/saving/creating projects) — if the user asks for one of those, tell them what to \
    click in the app instead of attempting it. Track/clip/take ids in the context below are \
    shown as an 8-character prefix like [a1b2c3d4]; pass that short id (or a full UUID) as any \
    *Id parameter and it will be resolved. Prefer a few precise tool calls over many small ones.
    """

    // MARK: - Session context (§4)

    /// Rebuilds a plain-text project summary plus an 8-char-prefix -> UUID
    /// expansion map, from live `ProjectStore` state. Pure function (aside
    /// from reading `store`), directly unit-testable.
    static func buildContext(store: ProjectStore) -> (text: String, idMap: [String: UUID]) {
        var allIDs: [UUID] = []
        for track in store.tracks {
            allIDs.append(track.id)
            for clip in track.clips { allIDs.append(clip.id) }
            for group in track.takeGroups { allIDs.append(group.id) }
        }

        // Prefix collisions: entries sharing an 8-char short id are excluded
        // from the map and printed full-length instead.
        var idsByShort: [String: Set<UUID>] = [:]
        for id in allIDs {
            idsByShort[id8(id), default: []].insert(id)
        }
        var idMap: [String: UUID] = [:]
        for (short, ids) in idsByShort where ids.count == 1 {
            idMap[short] = ids.first!
        }
        func label(_ id: UUID) -> String {
            let short = id8(id)
            return idMap[short] == id ? "[\(short)]" : "[\(id.uuidString)]"
        }

        var lines: [String] = []
        let dirtySuffix = store.isDirty ? " (unsaved changes)" : ""
        lines.append("PROJECT: \"\(store.projectName)\"\(dirtySuffix)")

        let transport = store.transport
        let stateWord = transport.isRecording ? "recording" : (transport.isPlaying ? "playing" : "stopped")
        let loopText = transport.isLoopEnabled
            ? "\(fmt(transport.loopStartBeat))-\(fmt(transport.loopEndBeat))"
            : "off"
        let metronomeText = transport.isMetronomeEnabled ? "on" : "off"
        lines.append(
            "TRANSPORT: \(fmt(transport.tempoBPM)) BPM "
            + "\(transport.timeSignature.beatsPerBar)/\(transport.timeSignature.beatUnit) | "
            + "\(stateWord) @ beat \(fmt(transport.positionBeats)) | loop \(loopText) | "
            + "metronome \(metronomeText)")

        lines.append("MASTER: volume \(fmt(store.masterVolume))")
        lines.append("UNDO: \(store.undoLabel ?? "nothing to undo") / redo: \(store.redoLabel ?? "-")")

        let tracks = store.tracks
        let trackLimit = 24
        lines.append("TRACKS (\(tracks.count)):")
        for track in tracks.prefix(trackLimit) {
            var flags = ""
            if track.isMuted { flags += " MUTED" }
            if track.isSoloed { flags += " SOLO" }
            let aiTag = track.isAIGenerated ? " (AI)" : ""
            lines.append(
                "- \(label(track.id)) \"\(track.name)\" \(track.kind.rawValue)\(aiTag) | "
                + "vol \(fmt(track.volume)) pan \(fmt(track.pan))\(flags) | \(track.clips.count) clips")

            if !track.clips.isEmpty {
                let clipLimit = 8
                let shown = track.clips.prefix(clipLimit).map { clip -> String in
                    let aiClipTag = clip.isAIGenerated ? " (AI)" : ""
                    return "\(label(clip.id)) \"\(clip.name)\" @ "
                        + "\(fmt(clip.startBeat))..\(fmt(clip.startBeat + clip.lengthBeats))\(aiClipTag)"
                }
                var clipsLine = "    clips: " + shown.joined(separator: "; ")
                if track.clips.count > clipLimit {
                    clipsLine += "; +\(track.clips.count - clipLimit) more"
                }
                lines.append(clipsLine)
            }
            for group in track.takeGroups {
                lines.append(
                    "    takes: \(label(group.id)) \"\(group.name)\" "
                    + "\(group.lanes.count) lanes, \(group.comp.count) comp segments")
            }
        }
        if tracks.count > trackLimit {
            lines.append("+\(tracks.count - trackLimit) more tracks")
        }

        var text = lines.joined(separator: "\n")
        let cap = 8000
        if text.count > cap {
            let marker = "\n[context truncated — use project.snapshot for detail]"
            let budget = max(0, cap - marker.count)
            text = String(text.prefix(budget)) + marker
        }
        return (text, idMap)
    }

    /// First 8 lowercase hex chars of a UUID's string form (the leading
    /// dash-delimited group is already exactly 8 hex chars).
    private static func id8(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    private static func fmt(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    // MARK: - Id-prefix expansion (§4)

    /// Expands short 8-char id prefixes back to full UUID strings in every
    /// TOP-LEVEL param whose key ends in "Id"/"ID" (except `jobId`, which
    /// names a sidecar job, not a project UUID). A value that already parses
    /// as a full UUID passes through untouched; a value matching neither also
    /// passes through untouched, letting the command's own UUID validation
    /// produce the actionable error (which returns to the model as a
    /// tool_result).
    static func expandIDs(_ params: [String: JSONValue], idMap: [String: UUID]) -> [String: JSONValue] {
        var result = params
        for (key, value) in params {
            guard key != "jobId", key.hasSuffix("Id") || key.hasSuffix("ID") else { continue }
            guard case .string(let raw) = value else { continue }
            if UUID(uuidString: raw) != nil { continue }
            if let full = idMap[raw.lowercased()] {
                result[key] = .string(full.uuidString)
            }
        }
        return result
    }

    // MARK: - Tool-result encoding

    private static func summarize(_ data: Data, limit: Int) -> String {
        let string = String(data: data, encoding: .utf8) ?? "{}"
        return capResult(string, limit: limit)
    }

    private static func encodedResultString(_ value: JSONValue?) -> String {
        guard let value else { return "{}" }
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func capResult(_ string: String, limit: Int) -> String {
        guard string.count > limit else { return string }
        let marker = "...[truncated]"
        let budget = max(0, limit - marker.count)
        return String(string.prefix(budget)) + marker
    }
}
