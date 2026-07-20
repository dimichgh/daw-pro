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
            /// A thinking block's visible summary text (M10-p-6) — see
            /// `CopilotContentBlock.thinking`. Never counted as VISIBLE
            /// output (§11.2): an all-thinking reply still takes the honest
            /// no-visible-output path even though the user can now SEE the
            /// reasoning that consumed the turn.
            case thinking(String)
            case toolCall(command: String, argsSummary: String)
            case toolResult(command: String, ok: Bool, summary: String)
            /// Provider/turn-level error, actionable text (never key material).
            case failure(String)
        }
        public let id: UUID
        public let turnID: String
        public var kind: Kind
        /// True while this entry is a live, still-streaming partial (its
        /// text may still grow) — M10-p-6's real-time partial transcript.
        /// Set on the ONE in-flight `.assistant`/`.thinking` entry per SSE
        /// blockIndex while `provider.complete`'s `onEvent` deltas arrive,
        /// cleared the moment the turn reconciles against the authoritative
        /// `reply.blocks` for that round (or, if the turn throws mid-stream,
        /// alongside the failure entry — no entry is ever left orphaned in
        /// the streaming state). Additive on the wire: `ai.copilotState`
        /// entries gain `partial: true` only while true, ABSENT once
        /// finalized (not merely `false`), so an existing client that
        /// doesn't know the field sees nothing different for a completed
        /// turn.
        public var partial: Bool = false

        public init(id: UUID, turnID: String, kind: Kind, partial: Bool = false) {
            self.id = id
            self.turnID = turnID
            self.kind = kind
            self.partial = partial
        }
    }

    // MARK: - Public state

    public private(set) var transcript: [TranscriptEntry] = []
    public private(set) var status: TurnStatus = .idle
    public private(set) var currentTurnID: String?

    // MARK: - Chat identity (chat-persist design §5.1)

    /// The ACTIVE conversation's stable id — what `persistableChatSnapshot()`
    /// persists under and what archive-on-reset upserts by. Minted fresh on
    /// reset/new-chat/project transition; adopted from the document on resume.
    public private(set) var currentChatID = UUID()
    /// Derived from the first user message on `send()` (≤
    /// `CopilotChatLimits.derivedTitleLength`); renameable; nil until then.
    public private(set) var chatTitle: String?
    public private(set) var chatCreatedAt = Date()
    /// Touched on send + turn end — the archive's eviction/sort key.
    /// Publicly readable (Phase D): the rail's chat-history list sorts the
    /// ACTIVE chat by the same key the wire does, from cheap live values —
    /// never a full persistence snapshot per redraw.
    public private(set) var chatUpdatedAt = Date()
    /// `droppedEntries` inherited from a resumed truncated chat (L6) — the
    /// base the snapshot's own cap-drops add onto.
    private var inheritedDroppedEntries = 0
    /// Read-only honesty surface for the wire/UI phases (the `ai.copilotState`
    /// `droppedEntries` field and the "earlier messages trimmed" banner).
    public var chatDroppedEntries: Int { inheritedDroppedEntries }

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
    /// Resolves the copilot's current Anthropic model id (M10-p-6), read
    /// FRESH each turn — the `maxToolRoundsResolver` precedent. The
    /// bootstrap injects `{ copilotModelStore.effectiveModel }`.
    private let modelResolver: @MainActor () -> String
    /// Persists a model-id change for subsequent turns. No validation at
    /// this layer (see `setModel(_:)`); the bootstrap injects
    /// `{ copilotModelStore.commit($0) }`.
    private let modelSetter: @MainActor (String) -> Void
    private let historyLimit: Int

    /// Provider-facing conversation history (trimmed; see `trimHistory()`).
    /// Distinct from `transcript`, which is the unbounded UI surface.
    private var history: [CopilotMessage] = []
    private var turnTask: Task<Void, Never>?

    /// Per-round SSE block-index -> transcript-entry map (M10-p-6), so a live
    /// `onEvent` delta updates the SAME partial entry in place instead of
    /// duplicating one per delta. Reset at the top of every round (block
    /// indices are round-scoped — they restart at 0 on each new provider
    /// response). Keyed by the entry's stable `id` (not its transcript ARRAY
    /// index): `onEvent` is awaited from across a network read, and `reset()`
    /// can legitimately empty `transcript` out from under an in-flight turn,
    /// so a raw array index captured before that would be a stale/OOB hazard
    /// — looking the id back up via `firstIndex(where:)` is immune to that
    /// race (a missing id after a reset simply no-ops).
    ///
    /// This is MainActor-isolated INSTANCE state, not a local variable the
    /// `onEvent` closure captures by reference, because that closure must be
    /// `@Sendable` (the `CopilotProviding.complete` contract) — and a
    /// `@Sendable` closure cannot capture a local `var` mutably across calls.
    /// Routing through `self`'s own isolated storage sidesteps that cleanly.
    private var partialEntryIDByBlockIndex: [Int: UUID] = [:]

    /// The engine's own model-selection fallback when the app doesn't inject
    /// a `modelResolver`/`modelSetter` pair (most tests, and any call site
    /// from before M10-p-6). A fresh instance PER ENGINE — never a
    /// shared/static default, which would let one engine's `setModel` leak
    /// into another's `currentModel` reads (a test-isolation hazard the
    /// `CopilotLimitsStore`/`ControlPortStore` precedents avoid by always
    /// being explicitly constructed per test).
    @MainActor
    private final class DefaultModelBox {
        var model = AnthropicModelCatalog.defaultModelID
    }

    public init(
        store: ProjectStore,
        dispatch: @escaping @MainActor (ControlRequest) async -> ControlResponse,
        provider: (@MainActor () throws -> any CopilotProviding)? = nil,
        catalog: [CopilotTool] = CopilotToolCatalog.v1,
        maxToolRounds: @escaping @MainActor () -> Int = { CopilotLimits.defaultMaxRounds },
        modelResolver: (@MainActor () -> String)? = nil,
        modelSetter: (@MainActor (String) -> Void)? = nil,
        historyLimit: Int = 20
    ) {
        self.store = store
        self.dispatch = dispatch
        self.providerFactory = provider
        self.catalog = catalog
        self.catalogByCommand = Dictionary(uniqueKeysWithValues: catalog.map { ($0.command, $0) })
        self.maxToolRoundsResolver = maxToolRounds
        self.historyLimit = historyLimit
        if let modelResolver, let modelSetter {
            self.modelResolver = modelResolver
            self.modelSetter = modelSetter
        } else {
            let box = DefaultModelBox()
            self.modelResolver = { box.model }
            self.modelSetter = { box.model = $0 }
        }
        // Chat-persist wiring (§4.1/§11.6), done HERE — the one construction
        // point both the app bootstrap and every test fixture pass through —
        // so the app path and the engine-loop tests can never silently
        // diverge on it. The store holds the engine only WEAKLY through
        // these closures (the router's `copilotEngine` weak-backref
        // precedent); the engine already holds the store strongly, so this
        // adds no cycle.
        store.copilotActiveChatProvider = { [weak self] in self?.persistableChatSnapshot() }
        store.copilotProjectBoundaryHandler = { [weak self] in self?.projectDidTransition() }
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

        // Chat-persist §5.2: derive the chat title from the FIRST user
        // message, touch the archive sort key, and arm the store's chat-dirty
        // autosave paths (the active chat's growth is invisible to the store
        // otherwise). Capture the project generation for the §5.4 cross-
        // project turn guard — a fixed per-turn value, the maxRounds pattern.
        if chatTitle == nil {
            chatTitle = CopilotChatMapping.deriveTitle(from: message)
        }
        chatUpdatedAt = Date()
        store.noteCopilotChatActivity()
        let turnGeneration = store.projectGeneration

        turnTask = Task { [weak self] in
            await self?.runTurn(
                turnID: turnID, provider: resolvedProvider, maxRounds: effectiveMaxRounds,
                turnGeneration: turnGeneration)
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

    /// Cancels any in-flight turn, ARCHIVES the current conversation into
    /// the project, and starts a fresh empty chat — reset is
    /// archive-and-start-fresh, never destructive (chat-persist L5; the one
    /// destructive verb is `deleteChat`). Returns the archived chat's id
    /// (nil when the conversation was empty — nothing to archive) plus the
    /// id of any chat the archive cap evicted (§7.1, never silent); the wire
    /// surfaces both additively (Phase C).
    @discardableResult
    public func reset() -> (archivedChatId: UUID?, evictedChatId: UUID?) {
        turnTask?.cancel()
        turnTask = nil
        var archivedChatId: UUID?
        var evictedChatId: UUID?
        if let snapshot = persistableChatSnapshot() {
            archivedChatId = snapshot.id
            evictedChatId = store.archiveCopilotChat(snapshot)
        }
        startFreshChat()
        return (archivedChatId, evictedChatId)
    }

    /// Snapshot of the ACTIVE conversation for persistence — what
    /// `store.copilotActiveChatProvider` is wired to, so every save/autosave
    /// captures the live chat (the `instrumentStateProvider` pattern), and
    /// what reset/resume archive through. L3: `partial: true` entries are
    /// dropped by the mapping — a snapshot taken mid-turn reads as a
    /// consistent, completed prefix. nil for an empty conversation (a fresh
    /// chat is never noise-persisted).
    public func persistableChatSnapshot() -> CopilotChatDocument? {
        let snapshot = CopilotChatMapping.snapshot(
            transcript: transcript,
            history: history,
            id: currentChatID,
            title: chatTitle,
            createdAt: chatCreatedAt,
            updatedAt: chatUpdatedAt,
            model: currentModel,
            inheritedDropped: inheritedDroppedEntries)
        guard !snapshot.transcript.isEmpty || !snapshot.providerMessages.isEmpty else { return nil }
        return snapshot
    }

    /// Resumes an archived chat (chat-persist §5.2): archives the current
    /// conversation first (L5 — never lost; its id rides back as
    /// `archivedChatId`), then restores the chosen chat's transcript and
    /// SANITIZED provider history (§5.3). Model-switch-safe by construction:
    /// persisted history carries no thinking blocks (L1), so any curated
    /// model can continue the conversation. Throws a teaching error while a
    /// turn is running or for an unknown id — the engine-side guards behind
    /// the Phase C wire verb `ai.copilotResumeChat`.
    @discardableResult
    public func resumeChat(id: UUID) throws -> (archivedChatId: UUID?, evictedChatId: UUID?) {
        guard status != .running else {
            throw ControlError(
                "a copilot turn is already running — wait for it (poll ai.copilotState) "
                + "or ai.copilotReset to cancel and archive it first")
        }
        // Take FIRST — the take doubles as the existence check (an unknown
        // id throws before anything changes), and with the resumed chat
        // already out of the archive, archiving the current chat below can
        // never evict it; nothing after the take can fail, so the swap has
        // no window where both conversations are off the books.
        guard let document = store.takeCopilotChat(id: id) else {
            throw ControlError("unknown chatId '\(id.uuidString)' — list chats with ai.copilotChats")
        }
        var archivedChatId: UUID?
        var evictedChatId: UUID?
        if let snapshot = persistableChatSnapshot() {
            archivedChatId = snapshot.id
            evictedChatId = store.archiveCopilotChat(snapshot)
        }
        turnTask = nil
        let restored = CopilotChatMapping.restore(document)
        transcript = restored.transcript
        history = CopilotChatMapping.sanitizeProviderHistory(restored.history)
        partialEntryIDByBlockIndex = [:]
        currentTurnID = nil
        status = .idle
        currentChatID = document.id
        chatTitle = document.title
        chatCreatedAt = document.createdAt
        chatUpdatedAt = document.updatedAt
        inheritedDroppedEntries = (document.droppedEntries ?? 0) + restored.skippedEntries
        store.noteCopilotChatActivity()
        return (archivedChatId, evictedChatId)
    }

    /// Deletes a chat permanently — the ONE destructive chat verb (L5).
    /// Deleting the ACTIVE chat is allowed only while no turn is running: it
    /// drops the conversation and mints a fresh empty chat. Deleting an
    /// archived chat removes it from the store (allowed any time). Returns
    /// whether the deleted chat was the active one (`wasActive` on the wire).
    @discardableResult
    public func deleteChat(id: UUID) throws -> Bool {
        if id == currentChatID {
            guard status != .running else {
                throw ControlError(
                    "chat '\(id.uuidString)' is the active conversation and a turn is running "
                    + "— cancel it first (ai.copilotReset) or wait")
            }
            turnTask = nil
            startFreshChat()
            // The dropped conversation may already sit in saved files (the
            // active-chat upsert) — arm the autosave paths so the next save
            // erases its record too.
            store.noteCopilotChatActivity()
            return true
        }
        guard store.removeCopilotChat(id: id) else {
            throw ControlError("unknown chatId '\(id.uuidString)' — list chats with ai.copilotChats")
        }
        return false
    }

    /// Renames a chat, active or archived. Over-length titles are clamped to
    /// `CopilotChatLimits.maxTitleLength` (never an error); EMPTY-title
    /// validation is the command layer's job (Phase C — the `send`
    /// empty-message precedent). Throws for an unknown id.
    public func renameChat(id: UUID, title: String) throws {
        let clamped = String(title.prefix(CopilotChatLimits.maxTitleLength))
        if id == currentChatID {
            chatTitle = clamped
            store.noteCopilotChatActivity()
            return
        }
        guard store.renameCopilotChat(id: id, title: clamped) else {
            throw ControlError("unknown chatId '\(id.uuidString)' — list chats with ai.copilotChats")
        }
    }

    /// Session-boundary clear (chat-persist §4.5), wired to
    /// `store.copilotProjectBoundaryHandler`: project.open/new/recover
    /// replaces the session, so any in-flight turn is cancelled and the
    /// engine clears WITHOUT archiving — the old chat is already on the old
    /// project's disk via the transition flush (or was deliberately
    /// discarded, L5). The store bumps `projectGeneration` alongside, so
    /// even the cancellation window can't land a stale tool edit (§5.4).
    public func projectDidTransition() {
        turnTask?.cancel()
        turnTask = nil
        startFreshChat()
    }

    /// Returns all conversation + chat-identity state to a brand-new empty
    /// chat. The shared tail of reset/resume-archive/delete-active/transition.
    private func startFreshChat() {
        transcript = []
        history = []
        partialEntryIDByBlockIndex = [:]
        currentTurnID = nil
        status = .idle
        currentChatID = UUID()
        chatTitle = nil
        chatCreatedAt = Date()
        chatUpdatedAt = Date()
        inheritedDroppedEntries = 0
    }

    /// Awaits the stored turn `Task`, for deterministic test/rail-d
    /// completion without polling. A no-op if no turn has ever run.
    public func waitForTurn() async {
        await turnTask?.value
    }

    /// The copilot's currently effective Anthropic model id (M10-p-6) —
    /// `AIConfig.anthropicModel` for the NEXT turn's provider resolution.
    /// Reads the injected `modelResolver` fresh, the `maxToolRoundsResolver`
    /// precedent (a live Settings change is honored without live-patching
    /// the engine).
    public var currentModel: String { modelResolver() }

    /// Sets the copilot's model for subsequent turns. No validation at this
    /// layer — `ai.copilotSetModel` (`Commands.swift`) validates against
    /// `AnthropicModelCatalog.curated` and returns a teaching error BEFORE
    /// ever calling this, the same split as `send`'s empty-message check
    /// living at the command layer, not here. Takes effect starting with the
    /// NEXT turn's `resolveProvider()` call — an in-flight turn is never
    /// retargeted mid-flight.
    public func setModel(_ modelID: String) {
        modelSetter(modelID)
    }

    /// The `ai.copilotState` payload. `turnID == nil` returns the whole
    /// session's transcript; a non-nil `turnID` filters to that turn's
    /// entries — including an UNKNOWN turnId, which simply filters to an
    /// empty transcript (poller-friendly, not an error) while `status` and
    /// `currentTurnId` still report the engine's actual current turn.
    ///
    /// Chat-persist §6.5 additive fields (Phase C): `chatId` (always — the
    /// active conversation's stable id), `chatTitle` (once derived/set, nil
    /// until the first `send()`), `droppedEntries` (only when > 0, L6). This
    /// is the ONE place `ai.copilotState`'s shape is assembled, so the
    /// additive fields live here rather than duplicated in the command
    /// layer (`Commands.swift`'s `ai.copilotState` case stays a pure
    /// passthrough). No existing field's shape changes.
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
            "chatId": .string(currentChatID.uuidString),
        ]
        if let currentTurnID {
            object["currentTurnId"] = .string(currentTurnID)
        }
        if let chatTitle {
            object["chatTitle"] = .string(chatTitle)
        }
        if chatDroppedEntries > 0 {
            object["droppedEntries"] = .number(Double(chatDroppedEntries))
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
    ///
    /// Chat-persist note: seeding stays DESTROY-without-archive — the state
    /// it replaces is never archived (capture/debug tier; seeded fakes must
    /// never pollute the project's chat list).
    public func seedForCapture(turnID: String, status: TurnStatus, entries: [TranscriptEntry.Kind],
                               droppedEntries: Int = 0) {
        seedForCapture(turnID: turnID, status: status,
                       transcript: entries.map { TranscriptEntry(id: UUID(), turnID: turnID, kind: $0) },
                       droppedEntries: droppedEntries)
    }

    /// Full-entry variant (M10-p-6 UI phase, additive): lets `debug.copilotSeed`
    /// stage LIVE-STREAMING states — entries carrying `partial: true` — which the
    /// kind-only overload cannot express (it always seeds finalized entries).
    /// Same contract: capture-tier only, never a provider call; the streaming
    /// turn loop (`applyStreamEvent`/`finalizeStreamedEntry`) is untouched.
    ///
    /// Phase D additions (both additive, defaulted so every existing caller
    /// compiles unchanged): `droppedEntries` stages the L6 truncation banner
    /// (set UNCONDITIONALLY — a fresh seed never inherits a previous seed's
    /// banner), and the chat title is re-derived from the seeded transcript's
    /// first user entry (nil when it has none) so the header's current-chat
    /// line reads honestly over seeded fakes. `chatUpdatedAt` is touched so
    /// the active row's relative time reads "just now" in a capture.
    public func seedForCapture(turnID: String, status: TurnStatus, transcript: [TranscriptEntry],
                               droppedEntries: Int = 0) {
        turnTask?.cancel()
        turnTask = nil
        self.transcript = transcript
        self.status = status
        currentTurnID = status == .idle ? nil : turnID
        inheritedDroppedEntries = max(0, droppedEntries)
        chatTitle = transcript.lazy.compactMap { entry -> String? in
            if case .user(let text) = entry.kind { return CopilotChatMapping.deriveTitle(from: text) }
            return nil
        }.first
        chatUpdatedAt = Date()
    }

    // MARK: - Turn loop (§5)

    private func runTurn(
        turnID: String, provider: any CopilotProviding, maxRounds: Int, turnGeneration: UInt64
    ) async {
        do {
            for round in 0..<maxRounds {
                // Chat-persist §5.4/§5.5 — checked at the top of every round:
                // a reset/resume/transition retired this turn (silent return —
                // the engine already presents its next state), and a project
                // generation bump means open/new/recover replaced the session
                // (belt & suspenders behind the boundary handler: everything
                // is MainActor-serialized, so check-then-dispatch has no
                // interleaving gap and a stale turn can never land a tool
                // edit on the newly opened project).
                guard currentTurnID == turnID else { return }
                guard store.projectGeneration == turnGeneration else {
                    appendTranscript(turnID: turnID, .failure("project changed mid-turn — cancelled"))
                    concludeTurn(turnID: turnID, .cancelled)
                    return
                }
                // Rebuilt EVERY round: mid-turn tool calls mutate the
                // project, and the model must see the results.
                let (contextText, idMap) = Self.buildContext(store: store)
                let request = CopilotTurnRequest(
                    system: Self.systemPrompt + "\n\n" + contextText,
                    messages: history,
                    tools: catalog.map { $0.spec() },
                    // No artificial cap (nil): the provider requests its
                    // model's own maximum output tokens and — for Anthropic,
                    // the primary path — streams the response, so thinking +
                    // a long visible answer + tool calls can never be
                    // truncated by OUR budget, and the open connection
                    // survives past any fixed request timeout (the
                    // "(no response)"/"The request timed out." defects a
                    // fixed 4096/16000 cap used to cause). §11.2 below stays
                    // honest either way: a TRUE model-side max_tokens stop is
                    // still possible at the model's own ceiling and is still
                    // reported, never silently swallowed.
                    maxTokens: nil
                )
                // Fresh per round (M10-p-6): SSE block indices restart at 0
                // on every new provider response, so a stale mapping from a
                // PRIOR round must never be consulted for this one.
                partialEntryIDByBlockIndex = [:]
                let reply = try await provider.complete(request, onEvent: { [weak self] event in
                    await self?.applyStreamEvent(turnID: turnID, event: event)
                })
                // §5.5 — the engine was reset/resumed/transitioned while the
                // provider await was in flight: the fresh state must not be
                // touched (not even with a `.cancelled` overwrite).
                guard currentTurnID == turnID else { return }
                try Task.checkCancellation()

                var toolUses: [(id: String, name: String, inputJSON: Data)] = []
                var sawVisibleOutput = false
                for (blockIndex, block) in reply.blocks.enumerated() {
                    switch block {
                    case .text(let text):
                        sawVisibleOutput = true
                        finalizeStreamedEntry(turnID: turnID, blockIndex: blockIndex, kind: .assistant(text))
                    case .toolUse(let id, let name, let inputJSON):
                        sawVisibleOutput = true
                        toolUses.append((id, name, inputJSON))
                        appendTranscript(turnID: turnID, .toolCall(
                            command: CopilotTool.command(fromToolName: name),
                            argsSummary: Self.summarize(inputJSON, limit: 300)))
                    case .toolResult:
                        // Providers never emit tool_result in a reply; ignore defensively.
                        continue
                    case .thinking(let summary, _):
                        // §11.2 unchanged: a thinking block never counts as
                        // VISIBLE output, even with `display: "summarized"`
                        // surfacing real reasoning text — `sawVisibleOutput`
                        // stays untouched here. It DOES stay in
                        // `reply.blocks` below, so it still lands in
                        // `history` and gets echoed back verbatim on the
                        // next round (required by the Anthropic API — see
                        // `CopilotContentBlock.thinking`). A non-empty
                        // summary gets its own `.thinking` transcript entry
                        // (M10-p-6); an empty one (redacted, or `display:
                        // "omitted"`) has nothing to show, so only a stray
                        // partial (there shouldn't be one) gets finalized.
                        if summary.isEmpty {
                            finalizePartialIfPresent(blockIndex: blockIndex)
                        } else {
                            finalizeStreamedEntry(turnID: turnID, blockIndex: blockIndex, kind: .thinking(summary))
                        }
                    }
                }
                history.append(CopilotMessage(role: .assistant, blocks: reply.blocks))

                // Trust the BLOCKS over `stopReason` (§11.3): a reply with
                // tool_use blocks always executes them, even if stopReason
                // claimed endTurn.
                if toolUses.isEmpty {
                    // §11.2 (revised): "did the model say anything" is judged
                    // by VISIBLE output (text/tool_use), never by
                    // `reply.blocks.isEmpty` — an all-thinking reply is
                    // non-empty (it carries `.thinking` blocks) but produces
                    // nothing a human can see. The old code tested
                    // `blocks.isEmpty` and so silently emitted "(no
                    // response)" even when the model's whole token budget had
                    // gone to invisible reasoning; that string is never
                    // emitted anymore.
                    if !sawVisibleOutput {
                        if reply.stopReason == .maxTokens {
                            appendTranscript(turnID: turnID, .failure(
                                "the model hit the token limit before producing any visible output "
                                + "(its whole budget went to internal reasoning) — try again, simplify "
                                + "the request, or split it into steps"))
                            concludeTurn(turnID: turnID, .failed)
                            return
                        }
                        appendTranscript(turnID: turnID, .failure(
                            "the model returned no visible output (stop reason: \(Self.describe(reply.stopReason)))"))
                        // Never loop on an invisible reply: end the turn as
                        // `.done` (not `.failed`) to preserve the never-loop
                        // guarantee — this is a "nothing to show" turn, not a
                        // hard failure the caller must recover from.
                        concludeTurn(turnID: turnID, .done)
                        return
                    }
                    concludeTurn(turnID: turnID, .done)
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
                    // §5.4 — immediately before EVERY dispatch: the previous
                    // dispatch's await is a suspension point a
                    // reset/transition can complete inside, and a stale turn
                    // must never land a tool edit on a replaced session.
                    guard currentTurnID == turnID else { return }
                    guard store.projectGeneration == turnGeneration else {
                        appendTranscript(turnID: turnID, .failure("project changed mid-turn — cancelled"))
                        concludeTurn(turnID: turnID, .cancelled)
                        return
                    }
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
            concludeTurn(turnID: turnID, .done)
        } catch is CancellationError {
            // §5.5 (pre-existing bug, fixed with this feature): reset()
            // cancels the turn task and then rebuilds fresh state — but this
            // catch used to run AGAINST that fresh state, overwriting the
            // reset's `.idle` with `.cancelled` and appending a stray
            // "cancelled" failure entry (with the OLD turnID) to the NEW
            // empty transcript. A stale turn now exits silently.
            guard currentTurnID == turnID else { return }
            finalizeAllPartials()
            appendTranscript(turnID: turnID, .failure("cancelled"))
            concludeTurn(turnID: turnID, .cancelled)
        } catch {
            // AIServiceError (and friends) are already key-free/actionable.
            guard currentTurnID == turnID else { return }  // §5.5, as above
            finalizeAllPartials()
            appendTranscript(turnID: turnID, .failure(error.localizedDescription))
            concludeTurn(turnID: turnID, .failed)
        }
    }

    /// The single turn-terminal funnel (chat-persist §5.2): every
    /// `.done`/`.failed`/`.cancelled` lands here — sets the status, applies
    /// the L2 turn-end thinking strip (so in-memory history between turns ≡
    /// the persisted shape, and a mid-chat model switch can never replay a
    /// stale-model signature), touches the chat's `updatedAt`, and arms the
    /// store's chat-dirty autosave paths. Guarded per §5.5: a turn the
    /// engine already replaced mutates nothing.
    private func concludeTurn(turnID: String, _ terminal: TurnStatus) {
        guard currentTurnID == turnID else { return }
        status = terminal
        stripThinkingFromHistory()
        chatUpdatedAt = Date()
        store.noteCopilotChatActivity()
    }

    /// L2 — turn-end strip: removes `.thinking` blocks from the in-memory
    /// history (they are only load-bearing WITHIN a turn's tool-use rounds,
    /// where they stay verbatim exactly as before). An assistant message
    /// left with zero blocks becomes the placeholder text block — never
    /// dropped (alternation safety), never left empty (Anthropic 400s on
    /// empty content; this also heals the zero-block reply an invisible
    /// turn appends).
    private func stripThinkingFromHistory() {
        for index in history.indices {
            let kept = history[index].blocks.filter {
                if case .thinking = $0 { return false }
                return true
            }
            if kept.isEmpty, history[index].role == .assistant {
                history[index].blocks = [.text(CopilotChatMapping.noVisibleOutputPlaceholder)]
            } else {
                history[index].blocks = kept
            }
        }
    }

    // MARK: - Live partial transcript (M10-p-6)

    /// Applies one streamed delta to the live partial transcript entry for
    /// its `blockIndex`: the FIRST delta for an index appends a new
    /// `partial: true` entry of the right kind; every later delta for that
    /// same index updates its text in place — never duplicates. `@MainActor`,
    /// awaited from the provider's SSE loop via the `onEvent` closure
    /// `runTurn` hands it (see `CopilotStreamEvent`); awaiting preserves
    /// streamed ORDER end to end.
    private func applyStreamEvent(turnID: String, event: CopilotStreamEvent) {
        // Defensive: a reset() (or a brand-new turn starting) between when
        // this event was queued and now must never let a stale/cancelled
        // turn's delta mutate the CURRENT transcript.
        guard currentTurnID == turnID else { return }

        let blockIndex: Int
        let deltaText: String
        let isThinking: Bool
        switch event {
        case .thinkingDelta(let index, let text):
            blockIndex = index; deltaText = text; isThinking = true
        case .textDelta(let index, let text):
            blockIndex = index; deltaText = text; isThinking = false
        }

        if let entryID = partialEntryIDByBlockIndex[blockIndex],
           let entryArrayIndex = transcript.firstIndex(where: { $0.id == entryID }) {
            let existingText: String
            switch transcript[entryArrayIndex].kind {
            case .thinking(let text), .assistant(let text): existingText = text
            default: existingText = ""
            }
            transcript[entryArrayIndex].kind = isThinking
                ? .thinking(existingText + deltaText)
                : .assistant(existingText + deltaText)
        } else {
            let entry = TranscriptEntry(
                id: UUID(), turnID: turnID,
                kind: isThinking ? .thinking(deltaText) : .assistant(deltaText),
                partial: true)
            transcript.append(entry)
            partialEntryIDByBlockIndex[blockIndex] = entry.id
        }
    }

    /// Finalizes the round's live partial entry for `blockIndex` with the
    /// AUTHORITATIVE `kind` from `reply.blocks` (its text can differ
    /// trivially from the last delta, e.g. a stream that ends mid-multi-byte
    /// character reassembly) and clears `partial` — or, if no delta ever
    /// arrived for that index (`OpenAICopilotProvider`'s non-streaming reply;
    /// or defensively, a stream that produced a block with no matching
    /// event), appends a fresh non-partial entry instead. Either way, exactly
    /// ONE transcript entry per blockIndex — never a duplicate.
    private func finalizeStreamedEntry(turnID: String, blockIndex: Int, kind: TranscriptEntry.Kind) {
        if let entryID = partialEntryIDByBlockIndex[blockIndex],
           let entryArrayIndex = transcript.firstIndex(where: { $0.id == entryID }) {
            transcript[entryArrayIndex].kind = kind
            transcript[entryArrayIndex].partial = false
        } else {
            appendTranscript(turnID: turnID, kind)
        }
    }

    /// Clears `partial` on `blockIndex`'s entry (if any) without changing its
    /// kind/text — used for a `.thinking` block whose summary is empty
    /// (nothing new to show) but which may still have accumulated a
    /// (necessarily also-empty) partial entry defensively.
    private func finalizePartialIfPresent(blockIndex: Int) {
        guard let entryID = partialEntryIDByBlockIndex[blockIndex],
              let entryArrayIndex = transcript.firstIndex(where: { $0.id == entryID })
        else { return }
        transcript[entryArrayIndex].partial = false
    }

    /// Clears `partial` on every still-open entry from the round that was
    /// in-flight when the turn threw — the mid-stream-failure half of "no
    /// entry is ever left orphaned in the streaming state". The normal path
    /// finalizes per-block via `finalizeStreamedEntry` right after
    /// `provider.complete` returns; this covers the throw-BEFORE-that-point
    /// case (both `catch` clauses in `runTurn`).
    private func finalizeAllPartials() {
        for entryID in partialEntryIDByBlockIndex.values {
            guard let entryArrayIndex = transcript.firstIndex(where: { $0.id == entryID }) else { continue }
            transcript[entryArrayIndex].partial = false
        }
        partialEntryIDByBlockIndex = [:]
    }

    // MARK: - Provider resolution

    private func resolveProvider() throws -> any CopilotProviding {
        if let providerFactory {
            return try providerFactory()
        }
        return try resolveCopilotProvider(
            environment: ProcessInfo.processInfo.environment,
            store: KeychainKeyStore(),
            // M10-p-6: honor the persisted model setting for the Anthropic
            // path — `modelResolver()` is `AIConfig()`'s own default
            // ("claude-sonnet-5") when nothing has ever been set, so this is
            // a no-op for every caller that predates model selection. Only
            // `anthropicModel` is overridden; every other `AIConfig` field
            // (base URLs, OpenAI model ids, keys) stays at its own default —
            // `resolveCopilotProvider` fills in the actual key afterward.
            config: AIConfig(anthropicModel: modelResolver()))
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
        case .thinking(let text):
            object["kind"] = .string("thinking")
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
        // Additive (M10-p-6): present only while the entry is still
        // streaming — ABSENT once finalized, not merely `false`, so an
        // existing client that doesn't know the field sees nothing different
        // for a completed turn.
        if entry.partial {
            object["partial"] = .bool(true)
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

    // MARK: - Stop-reason description (§11.2)

    /// The wire term for a `CopilotReply.StopReason`, for the "no visible
    /// output" failure text — always Anthropic's own vocabulary (`end_turn`,
    /// `tool_use`, `max_tokens`), matching `.other`'s raw passthrough, since
    /// `mapStopReason` on both providers already normalizes onto this shared
    /// enum before it ever reaches the engine.
    private static func describe(_ reason: CopilotReply.StopReason) -> String {
        switch reason {
        case .endTurn: return "end_turn"
        case .toolUse: return "tool_use"
        case .maxTokens: return "max_tokens"
        case .other(let raw): return raw
        }
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
