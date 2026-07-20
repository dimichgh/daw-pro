# Design: Persistent Copilot Chat History (in-project, multi-chat, resumable)

**Status: design settled 2026-07-19 — implementation pending.** Author: daw-architect.
User requirement (verbatim): *"we need to preserve history of our chats, so we can
continue them and they should be stored within project file so we can re-open it."*

Precedents leaned on throughout: additive-optional `ProjectDocument` fields
(`grooveTemplates`/`markers`/`masterEffects`), the `instrumentStateProvider` save-time
capture closure, the `engine?.projectWillReplace()` store→app seam, `CopilotLimits`
(DAWCore policy consumed by DAWControl), and the rail-a copilot design
(docs/research/design-rail-a-copilot.md).

---

## 1. Decision

**Chats persist as an additive-optional `copilotChats` array inside `project.json`**
(the `.dawproj` bundle's document), owned at runtime by `ProjectStore` (archived
chats) + `CopilotEngine` (the one active chat), captured at serialization time
through a save-time provider closure — the `instrumentStateProvider` pattern.
`reset()` becomes **archive-and-start-fresh**; four new wire commands
(`ai.copilotChats`, `ai.copilotResumeChat`, `ai.copilotDeleteChat`,
`ai.copilotRenameChat`) plus matching MCP tools make every chat listable,
resumable, renamable, and deletable. Persisted provider history **never contains
thinking blocks** (Law L1 below). Chat mutations never enter the undo stack; they
ride a separate `chatsDirty` flag that joins every autosave/flush path so a crash
never loses a conversation. No schemaVersion bump.

### 1.1 Strongest alternatives, and why they lose

**A. Separate `chats.json` file inside the bundle.**
Pro: an OLD app build that opens+re-saves a new project would leave `chats.json`
untouched, so chats would survive an old-build round trip. Loses because: (1) every
existing serialization pathway — titled save, untitled recovery bundle, crash
autosave (`AutosaveManager.recordAutosave`), `recoverFromAutosave`, and
`writeFeedbackBundle` — flows through `ProjectDocument` + `ProjectBundle.write`;
an inline field rides **all five for free**, a sibling file forks every one of them.
(2) One atomic `project.json` write means chat state and project state can never be
torn apart by a crash mid-save; two files can. (3) Eight in-repo precedents settle
the house style as "additive optional field on `ProjectDocument`, omit-when-empty,
no schema bump". The old-build survival benefit is marginal for a beta app whose
builds move forward together, and `project.json` already inlines multi-MiB AU
`stateData`, so "keep the document lean" is not a live constraint.

**B. Per-user chat library outside the project (Application Support, keyed by
project path).** Pro: zero project-format change, no size pressure on the bundle.
Loses outright: it violates the user's explicit ask — chats must live *within the
project file* so copying/archiving/sharing the `.dawproj` carries the conversations
with it, and re-opening on another machine still resumes them.

**C. (State-ownership sub-decision) Engine-owned archive vs store-owned.**
Engine-owned loses: DAWCore cannot see DAWControl, so save/open would need the
engine pushed into the persistence path (dependency inversion), headless DAWCore
persistence tests couldn't cover chats, and "one command surface converges on
ProjectStore" would be broken for chat state. Store owns the archive; the engine
owns only the live conversation and snapshots it on demand.

**D. (Fidelity sub-decision) Persist transcript only, rebuild provider history
from it.** Simpler and smaller, loses because transcript tool summaries are capped
at 300 chars vs the 4000-char results the model actually saw — a resumed chat would
give the model a lossier memory of what it already did. We persist both surfaces
(display transcript + provider messages), each already bounded.

---

## 2. Laws (load-bearing; do not "fix" later)

**L1 — Thinking blocks are never persisted in provider history.**
Anthropic's verbatim-echo requirement for `thinking`/`redacted_thinking` blocks
(see `CopilotContentBlock.thinking` in `Sources/AIServices/CopilotProvider.swift`)
is load-bearing **only within an in-flight tool-use loop** — the rounds of one
turn. Persisted chats only ever exist at turn boundaries, where the blocks are not
required, and their signatures may not validate after a model switch. Therefore:
any persisted `providerMessages` **strip `.thinking` blocks**. The thinking
*summaries* stay in the persisted **transcript** (kind `"thinking"`) for display.
Implementers: this is not data loss — it is the only shape that makes resumed chats
model-switch-safe. Never round-trip `rawJSON` to disk.

**L2 — Turn-end strip.** At the end of every turn (`.done`/`.failed`/`.cancelled`),
the engine strips `.thinking` blocks from its **in-memory** `history` too. An
assistant message left with zero blocks is **replaced by**
`.text("(the model produced no visible output this turn)")` — never dropped
(alternation safety with the pinned `anthropic-version`), never left empty
(Anthropic 400s on empty content). Within a turn's rounds, thinking blocks stay in
`history` verbatim exactly as today. Corollary: in-memory history between turns ≡
persisted shape, so snapshot/resume is a trivial map and a mid-chat model switch
can never replay a stale-model signature.

**L3 — Finalize-or-drop on persist.** A snapshot taken while a turn is streaming
(`status == .running` — autosave fires mid-turn) **drops** every
`partial == true` transcript entry. Partials are finalized only by the turn loop,
never by the persistence path. A persisted chat therefore always reads as a
consistent, completed prefix of the conversation.

**L4 — Chats never touch the undo stack or the edit journal.** No `performEdit`,
no `UndoJournal` entry, no `lastEditEvent` bump, no engine notification. Chat
mutations bump `chatRevision` + set `chatsDirty` only.

**L5 — Non-destructive by default.** `reset()` archives; `resumeChat` archives the
current chat before swapping; the **only** destructive verb is
`ai.copilotDeleteChat`. `discardChanges: true` on `project.open`/`project.new`
discards unsaved chats along with every other unsaved change — that is what
"discard" means, and it is stated in the command docs.

**L6 — Truncation is always visible.** Any cap-driven drop of transcript entries
is counted in the chat's `droppedEntries` and surfaced on the wire and in the UI
("earlier messages trimmed"). The persisted transcript never silently pretends to
be complete.

---

## 3. Data model (DAWCore — new file `Sources/DAWCore/CopilotChat.swift`)

Pure Codable DTOs. String-typed `kind`/`type`/`role` discriminators so a file
written by a FUTURE build (new entry kinds) still decodes today (unknown kinds are
skipped on resume and counted into `droppedEntries`, per L6).

```swift
/// One persisted copilot conversation — the disk twin of the engine's
/// transcript + (thinking-stripped, L1) provider history.
public struct CopilotChatDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String            // derived from first user message; renameable
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?           // last model in effect (informational only)
    public var droppedEntries: Int?     // L6 honesty counter; omit when 0/absent
    public var transcript: [Entry]
    public var providerMessages: [ProviderMessage]

    /// Field names deliberately mirror `stateJSON`'s wire entry shape.
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var turnId: String
        public var kind: String         // "user"|"assistant"|"thinking"|"toolCall"|"toolResult"|"failure"
        public var text: String?        // user/assistant/thinking/failure
        public var command: String?     // toolCall/toolResult
        public var ok: Bool?            // toolResult
        public var summary: String?     // toolCall(args)/toolResult
    }

    public struct ProviderMessage: Codable, Sendable, Equatable {
        public var role: String         // "user" | "assistant"
        public var blocks: [Block]
        public struct Block: Codable, Sendable, Equatable {
            public var type: String     // "text" | "toolUse" | "toolResult" — NEVER "thinking" (L1)
            public var text: String?            // text
            public var toolUseId: String?       // toolUse / toolResult
            public var name: String?            // toolUse (wire tool name)
            public var inputJSON: String?       // toolUse input, UTF-8 JSON text
            public var content: String?         // toolResult
            public var isError: Bool?           // toolResult
        }
    }
}

/// Persistence policy (beside `CopilotLimits` — same DAWCore-policy precedent).
public enum CopilotChatLimits {
    public static let maxArchivedChats = 20            // active chat excluded
    public static let maxPersistedTranscriptEntries = 400
    public static let maxPersistedChatBytes = 262_144  // 256 KiB soft cap per chat
    public static let maxTitleLength = 120
    public static let derivedTitleLength = 60
    public static let totalChatBytesWarningThreshold = 4 * 1024 * 1024
}
```

Also in this file: a small `LossyArray<Element: Codable>` helper (decodes an
unkeyed container element-by-element, skipping elements that fail to decode and
counting them) so **one corrupt chat can never fail a whole project open**. The
skip count surfaces as an open warning ("N copilot chats could not be read and
were dropped").

### 3.1 `ProjectDocument` change (`Sources/DAWCore/ProjectDocument.swift`)

```swift
/// Persisted copilot conversations (chat-persist design, 2026-07-19). Additive
/// and optional; nil when there are none (omit-when-empty — the grooveTemplates
/// rule, no schemaVersion bump). Decoded LOSSILY: a corrupt element is skipped
/// (counted into `copilotChatsDroppedOnLoad`), never fatal to the open.
public var copilotChats: [CopilotChatDocument]?
/// Transient decode fact, NOT coded: how many chat elements failed to decode.
public var copilotChatsDroppedOnLoad: Int = 0
```

- `CodingKeys` gains `copilotChats` (the transient counter is not a key).
- Custom `init(from:)`: `copilotChats` via `LossyArray` + `decodeIfPresent`;
  `copilotChatsDroppedOnLoad` from the lossy wrapper.
- Memberwise `init(...)` gains `copilotChats: [CopilotChatDocument] = []`,
  stored as `isEmpty ? nil : chats` (the omit-when-empty rule).
- `runtimeState(bundleURL:)` is untouched (chats carry no media); the open path
  reads `document.copilotChats ?? []` directly and appends the dropped-count
  warning when `copilotChatsDroppedOnLoad > 0`.

### 3.2 Format-version & compatibility note

- **No schemaVersion bump** (stays 1). Absent key decodes to nil → `[]`. A
  pre-chat project re-saved with no chats stays **byte-identical** (nil → key
  omitted by the synthesized `encodeIfPresent`).
- **Backward compat (new app, old file):** opens unchanged, zero chats.
- **Forward compat (old app, new file) — stated honestly:** an old build opens the
  file fine (`JSONDecoder` ignores the unknown `copilotChats` key) and the session
  behaves normally, but the chats are invisible there, and the old build's **next
  save rewrites `project.json` without them — the chats are lost**. This is the
  accepted trade of alternative A (§1.1) and is the same forward-compat behavior
  every additive field in this format already has. Recovery bundles behave
  identically.

---

## 4. ProjectStore changes (`Sources/DAWCore/ProjectStore.swift`)

### 4.1 New state

```swift
// MARK: - Copilot chats (persisted; docs/research/design-copilot-chat-persistence.md)
/// ARCHIVED chats only — the active conversation lives in CopilotEngine and is
/// captured through `copilotActiveChatProvider` at serialization time.
public private(set) var copilotChats: [CopilotChatDocument] = []
/// Chat-content twin of `isDirty` (L4): set by chat mutations, cleared by
/// save/open/new. Deliberately SEPARATE — the UI unsaved-changes indicator, the
/// copilot context "(unsaved changes)" line, and the edit journal all keep
/// keying on `isDirty` alone; chats ride the autosave paths silently.
public private(set) var chatsDirty = false
/// Monotonic chat mutation counter — the crash-autosave staleness token for
/// chats (the `lastEditEvent.seq` analogue; never journaled, L4).
public private(set) var chatRevision: UInt64 = 0
/// Bumped on every session replacement (open/new/recover). CopilotEngine
/// captures it at turn start and refuses to dispatch tools across a boundary
/// (§5.4) — the defense-in-depth guard behind the boundary handler.
public private(set) var projectGeneration: UInt64 = 0

/// Save-time capture of the ACTIVE chat (the instrumentStateProvider
/// precedent). Wired by the app bootstrap to CopilotEngine.persistableChatSnapshot().
@ObservationIgnored public var copilotActiveChatProvider: (() -> CopilotChatDocument?)?
/// Session-boundary notification (the engine?.projectWillReplace() analogue,
/// pointed the other way). Wired to CopilotEngine.projectDidTransition().
@ObservationIgnored public var copilotProjectBoundaryHandler: (() -> Void)?
```

### 4.2 New methods (all `@MainActor`, none journaled — L4)

```swift
/// Upserts by id (a re-archived resumed chat replaces its old record, never
/// duplicates). At the cap, evicts the oldest-`updatedAt` ARCHIVED chat and
/// returns its id (nil otherwise). Bumps chatRevision, sets chatsDirty.
@discardableResult
public func archiveCopilotChat(_ chat: CopilotChatDocument) -> UUID?
/// Removes and returns a chat for resumption (it becomes the engine's active
/// chat). Bumps chatRevision, sets chatsDirty. nil for an unknown id.
public func takeCopilotChat(id: UUID) -> CopilotChatDocument?
@discardableResult public func removeCopilotChat(id: UUID) -> Bool
@discardableResult public func renameCopilotChat(id: UUID, title: String) -> Bool
/// The engine's turn-boundary dirty hook: send() and turn completion call this
/// so the ACTIVE chat's growth (which the store cannot see) still arms the
/// autosave paths. Bumps chatRevision, sets chatsDirty.
public func noteCopilotChatActivity()
/// archived ⊎ active snapshot (upserted by id via copilotActiveChatProvider,
/// nil provider / empty chat skipped), sorted by updatedAt ascending. The ONE
/// array every serialization pathway passes to ProjectDocument.
func copilotChatsForPersistence() -> [CopilotChatDocument]
```

### 4.3 Serialization pathways (all five, one array)

- `saveProject`: `ProjectDocument(... copilotChats: copilotChatsForPersistence())`;
  on success `chatsDirty = false`. New save warning when the encoded chats total
  exceeds `totalChatBytesWarningThreshold`:
  `"copilot chat history is large (N MiB) — delete old chats (ai.copilotDeleteChat) to slim the project"`
  (the `audioUnitStateSoftCapBytes` stateWarnings precedent — warn, never refuse).
- `buildAutosaveDocument()`: same argument → **crash autosave, untitled recovery
  bundle, and recovery restore are covered automatically**.
- `writeFeedbackBundle` — **privacy exception**: `buildAutosaveDocument` gains
  `includeChats: Bool = true`; the feedback bundle passes `false`. Conversations
  (which may contain personal/lyrical content) never ride a diagnostics bundle,
  even with `includeProject: true`. Document this in the command's doc comment.

### 4.4 Dirty / autosave / flush / quit (constraint 4)

- `autosaveIfNeeded()` gate: `guard isDirty || chatsDirty` (titled → save in
  place also persists chats; untitled → recovery bundle carries them).
- `autosaveTick()` (crash autosave) gate: `guard isDirty || chatsDirty`;
  staleness: fire when `seq != lastAutosavedEditSeq || chatRevision != lastAutosavedChatRevision`.
  `AutosaveManager` gains `private(set) var lastAutosavedChatRevision: UInt64`
  (sentinel-reset in `invalidate()`, like the edit seq) and `recordAutosave`
  gains `chatRevision: UInt64 = 0` (additive, defaulted — existing tests
  compile unchanged). `manifest.json` is untouched (high-water marks are
  in-memory only).
- `flushForTransition()` gate: `guard isDirty || chatsDirty` — a chat-only
  session still flushes before open/new.
- **Clean quit:** the app's `applicationWillTerminate` path calls
  `store.autosaveIfNeeded()` before `endCrashDetection()` (a titled session
  saves in place; an untitled one writes its recovery bundle) so a conversation
  finished seconds before quit is never lost. (Today only the crash path would
  have covered it.)
- `isDirty` semantics, the UI dirty dot, and `buildContext`'s
  "(unsaved changes)" suffix are **unchanged** — chats are autosave-grade
  content, not "unsaved musical work".

### 4.5 Session boundaries (constraint 6)

`openProject` order (new steps marked ►):

```
guard !recording
document = ProjectBundle.read(...)          // throws → nothing changed
if !discardChanges { try flushForTransition() }
    // flush saves the OLD project INCLUDING the active chat, via
    // copilotChatsForPersistence() → no pre-archive step needed, and a flush
    // FAILURE aborts the open with the engine completely untouched.
if playing { stop() }
► copilotProjectBoundaryHandler?()          // engine clears WITHOUT archiving —
    // the old chat is already on the old project's disk (or deliberately
    // discarded via discardChanges, L5)
applyOpenedState(...):
    ► copilotChats = document.copilotChats ?? []
    ► chatsDirty = false
    ► projectGeneration &+= 1
    ► warnings += copilotChatsDroppedOnLoad warning if > 0
```

`newProject`: same shape — flush, handler, `copilotChats = []`,
`chatsDirty = false`, `projectGeneration &+= 1`.
`recoverFromAutosave(accept: true)`: handler after `readRecoveredDocument()`
succeeds, before `applyRecoveredState`; recovered state sets
`copilotChats = document.copilotChats ?? []`, `chatsDirty = true` (recovered
content is unsaved by definition), `projectGeneration &+= 1`. Any live active
chat at recover time is dropped un-archived (the pre-recover session is being
replaced wholesale — same law as `discardChanges`; in practice recovery happens
at launch with an empty chat).

**Open resumes idle.** After `project.open`, ALL persisted chats (including the
one that was active at save time) are archived and the engine starts a fresh
empty chat. Continuation is one explicit `ai.copilotResumeChat` / one click away.
Rationale: auto-resuming would silently re-arm a provider conversation the user
may not want billed/continued, and "most recent chat" is ambiguous after
cross-machine copies. The UI phase MAY add a "Continue last chat" affordance on
top (§8); the engine default stays fresh.

---

## 5. CopilotEngine changes (`Sources/DAWControl/CopilotEngine.swift`)

### 5.1 New state

```swift
public private(set) var currentChatID = UUID()
public private(set) var chatTitle: String?       // derived on first send; renameable
public private(set) var chatCreatedAt = Date()
private var chatUpdatedAt = Date()               // touched on send + turn end
/// droppedEntries inherited from a resumed truncated chat (L6) — the base the
/// snapshot's own cap-drops add onto.
private var inheritedDroppedEntries = 0
```

### 5.2 Lifecycle API (state machine)

| From | Event | To / effect |
|---|---|---|
| idle/done/failed/cancelled | `send()` | running (unchanged; + derive `chatTitle` if nil, `store.noteCopilotChatActivity()`, capture `turnGeneration = store.projectGeneration`) |
| running | turn ends | done/failed/cancelled (+ L2 strip, touch `chatUpdatedAt`, `noteCopilotChatActivity()`) |
| any | `reset()` | **archive-then-fresh**: cancel task; if transcript non-empty → build snapshot (L3 partials dropped) → `store.archiveCopilotChat` (may return evicted id); mint fresh `currentChatID`/`chatCreatedAt`, clear transcript/history/title, `.idle`. Returns `(archivedChatId: UUID?, evictedChatId: UUID?)` for the wire. |
| running | `resumeChat(id:)` | **throws** teaching error (see §6.2) |
| idle/done/failed/cancelled | `resumeChat(id:)` | archive current (if non-empty, same as reset), `store.takeCopilotChat(id:)` → map document → transcript + sanitized provider history (§5.3), adopt id/title/createdAt/droppedEntries, `.idle` |
| any | `projectDidTransition()` | cancel task; clear everything WITHOUT archiving (§4.5); fresh chat ids; `.idle` |
| idle-family | `deleteChat(id:)` where id == currentChatID | drop the active conversation permanently, mint fresh chat (the one destructive verb, L5) |
| running | `deleteChat(id: currentChatID)` | **throws** teaching error |
| any | `deleteChat(id:)` archived | `store.removeCopilotChat` |
| any | `renameChat(id:title:)` | active → set `chatTitle`; archived → `store.renameCopilotChat` |

`seedForCapture` stays destroy-without-archive (capture/debug tier — seeded
fakes must never pollute the project's chat list). Document that in its comment.

### 5.3 Snapshot & resume mapping (new file `Sources/DAWControl/CopilotChatMapping.swift`)

Pure static functions (unit-testable without an engine):

- `snapshot(transcript:history:id:title:createdAt:updatedAt:model:inheritedDropped:) -> CopilotChatDocument`
  — drops `partial == true` entries (L3); maps `TranscriptEntry.Kind` →
  string-kinded `Entry`; maps `CopilotMessage` → `ProviderMessage` with
  `.thinking` blocks stripped (L1) and all-thinking assistant messages replaced
  by the L2 placeholder; then applies caps (§7) and accumulates `droppedEntries`.
- `restore(_ doc: CopilotChatDocument) -> (transcript: [TranscriptEntry], history: [CopilotMessage], skippedEntries: Int)`
  — unknown `kind`/`type` strings are skipped and counted (forward tolerance);
  restored entries are always `partial: false`.
- `sanitizeProviderHistory(_ messages: [CopilotMessage]) -> [CopilotMessage]`
  — resume trust boundary for hand-edited/corrupt files: (1) drop leading
  messages until the head is a plain user TEXT message (the `trimHistory`
  invariant); (2) verify every `toolResult` id pairs with a `toolUse` in the
  immediately preceding assistant message, else return `[]` (display transcript
  survives; the conversation continues with fresh provider context — honest and
  safe, never a guaranteed 400 loop).

### 5.4 Cross-project turn guard (defense in depth)

`send()` captures `turnGeneration = store.projectGeneration`. `runTurn` checks
**at the top of every round and immediately before every `dispatch(...)`**:

```swift
guard currentTurnID == turnID else { return }                    // engine was reset/resumed/transitioned
guard store.projectGeneration == turnGeneration else {           // belt & suspenders
    appendTranscript(turnID: turnID, .failure("project changed mid-turn — cancelled"))
    status = .cancelled
    return
}
```

Because everything is MainActor-serialized, check-then-dispatch has no
interleaving gap: a `project.open` completes atomically between awaits, so a
stale turn can never land a tool edit on the newly opened project.

### 5.5 Existing-bug fix (found during this design — flag to implementers)

`reset()` today cancels the turn task, but the task's `catch` blocks then run
**against the freshly cleared state**: `status = .cancelled` overwrites the
reset's `.idle`, and a `.failure("cancelled")` entry with the OLD `turnID` is
appended to the NEW empty transcript (`appendTranscript` in both catch arms,
`Sources/DAWControl/CopilotEngine.swift` ~lines 463–472). Repro: `reset()` while
a provider await is in flight; poll `ai.copilotState` → stray `cancelled`
failure entry + `status: "cancelled"` in a supposedly fresh session. Fix (Phase
B, ships with this feature since archive-on-reset makes the window routine):
`guard currentTurnID == turnID else { return }` at the top of both catch blocks
and after `provider.complete` returns. Add a regression test.

---

## 6. Wire command specs (Commands.swift — all additive; counts 133 → 137)

House rules applied: `rejectUnknownKeys`, lowercase actionable teaching errors,
camelCase keys, ISO8601 date strings, absent-not-false optional flags. All four
new commands join `allCommands` AND `CopilotToolCatalog.neverInclude`
(`Sources/DAWControl/CopilotCatalog.swift` — the copilot must not manage its own
sessions mid-turn; same recursion-hygiene as the existing five), AND the
`ExplainModel` catalog (`Sources/DAWAppKit/ExplainModel.swift`) per the
every-command-explained law.

### 6.1 `ai.copilotChats` (new, read-only)

Params: none. Response:

```json
{ "chats": [ { "chatId": "UUID", "title": "add a funky bassline", "createdAt": "2026-07-19T10:00:00Z",
               "updatedAt": "2026-07-19T10:12:00Z", "entryCount": 12, "model": "claude-sonnet-5",
               "active": true, "droppedEntries": 40 } ],
  "activeChatId": "UUID" }
```

- Sorted by `updatedAt` descending. `active: true` present only on the engine's
  current chat (absent otherwise — the `partial` flag precedent); the active
  chat is listed **only when it has ≥ 1 entry** (a fresh empty chat is not
  noise-listed). `activeChatId` always present. `droppedEntries` present only
  when > 0 (L6). Never throws (engine-wired guard aside).

### 6.2 `ai.copilotResumeChat` (new)

Params: `chatId` (required, full UUID — chat ids are not in the copilot's
8-char idMap). Response:
`{ "chatId": "...", "title": "...", "entryCount": 12, "droppedEntries": 40, "status": "idle" }`
(`droppedEntries` only when > 0). Side effect: the current non-empty chat is
archived first (L5; its id is returned additively as `"archivedChatId"` when
that happened). Teaching errors:
- turn running: `a copilot turn is already running — wait for it (poll ai.copilotState) or ai.copilotReset to cancel and archive it first`
- unknown id: `unknown chatId '<value>' — list chats with ai.copilotChats`
- malformed: `'chatId' must be a UUID (from ai.copilotChats)`

Resume after a model switch is **allowed by construction** — persisted history
carries no thinking blocks (L1), so any curated model (or the OpenAI fallback)
can continue the conversation.

### 6.3 `ai.copilotDeleteChat` (new — the one destructive verb)

Params: `chatId` (required). Response:
`{ "deleted": true, "chatId": "...", "wasActive": false }`.
Deleting the ACTIVE chat is allowed when no turn is running: it drops the
conversation permanently and mints a fresh empty chat (`wasActive: true`).
Teaching errors: unknown id (as above); active-while-running:
`chat '<id>' is the active conversation and a turn is running — cancel it first (ai.copilotReset) or wait`.

### 6.4 `ai.copilotRenameChat` (new)

Params: `chatId` (required), `title` (required, trimmed non-empty, ≤ 120 chars —
over-length is clamped, not an error). Works on active or archived chats.
Response: `{ "chatId": "...", "title": "..." }`. Errors: unknown id; empty title:
`'title' must not be empty`.

### 6.5 Existing commands — additive changes only

- `ai.copilotReset`: request unchanged (still zero params). **Semantics change
  (deliberate, per the user requirement): archives instead of destroying.**
  Response gains additive `{ "archivedChatId": "...", "evictedChatId": "..." }`
  — both absent when nothing was archived/evicted. A client that ignores the
  result sees identical behavior modulo the chat list growing.
- `ai.copilotState`: response gains additive top-level fields `chatId` (always),
  `chatTitle` (once derived/set), `droppedEntries` (only when > 0). **No shape
  change to any existing field** (status/transcript/limits/currentTurnId are
  untouched).
- `project.open` / `project.new` doc comments: state explicitly that
  `discardChanges: true` also discards unsaved copilot chats (L5).

---

## 7. Size bounds & eviction (constraint 7)

Applied in `CopilotChatMapping.snapshot` (per chat) and
`ProjectStore.archiveCopilotChat` (per project):

1. **Per-project count:** max 20 archived chats (+1 active). Archiving at the
   cap evicts the oldest-`updatedAt` archived chat; the evicted id is returned
   up through `reset()`/`resumeChat` to the wire (`evictedChatId`) — never
   silent. Persistence-time upsert never evicts (the array can only reach
   cap+1 via the active snapshot).
2. **Per-chat transcript:** max 400 entries. Over-cap drops the **oldest whole
   turns** (turnId groups — a turn is never half-shown) until under; dropped
   count accumulates into `droppedEntries` (on top of any inherited count from
   a previous truncated persist/resume), L6.
3. **Per-chat bytes:** 256 KiB soft cap on the encoded chat. When over: first
   drop oldest provider **exchanges** (the `trimHistory` boundary law, min 1
   exchange kept — provider trims reduce only the model's memory, and the
   model already lives with `trimHistory`), then oldest transcript turns
   (counted into `droppedEntries`). Worst case ≈ 21 × 256 KiB ≈ 5.4 MiB — under
   the existing 8 MiB AU-state warning precedent.
4. **Project-level honesty:** the §4.3 save warning at 4 MiB total.
5. Provider history needs no count cap of its own — it is already ≤
   `historyLimit` (20 messages) by the live `trimHistory`, minus stripped
   thinking blocks.

---

## 8. UI-phase requirements (requirements only — pixel design is ui-design-engineer's)

All on `CopilotRailView` (`Sources/DAWApp/Copilot/CopilotRailView.swift`) +
`CopilotRailUIModel` (DAWAppKit, headless-testable), per DESIGN-LANGUAGE (dark
glass, violet = AI):

1. **Session list**: a header affordance (e.g. clock/history icon next to the
   reset button) opening the chat list — title, relative `updatedAt`, entry
   count; active chat pinned/marked; sorted like the wire (§6.1). Data via the
   same engine/store state the wire reads (never a self-WebSocket call).
2. **Resume affordance**: click a chat → resume. Disabled with an explanatory
   tooltip while a turn is running (mirror of the §6.2 teaching error).
3. **Current-chat indicator**: the derived/renamed title in the rail header
   (inline-renameable); a fresh empty chat reads as "New chat".
4. **Reset relabel**: the header reset button's help text becomes
   "Archive this conversation and start a new chat" (it no longer destroys —
   the current "Clear the conversation and start over" would now lie).
5. **Truncation banner** (L6): a resumed chat with `droppedEntries > 0` shows a
   dim, non-dismissable-lying banner at the transcript top: "Earlier messages
   were trimmed (N) to keep the project file small."
6. **Delete/rename**: per-row affordances; delete confirms (the one destructive
   act, L5).
7. Optional (nice-to-have, not required for the milestone): a "Continue last
   chat" one-tap affordance after `project.open` (engine default stays
   fresh-idle, §4.5).
8. Every one of these must remain drivable by `debug.copilotSeed` +
   `CopilotRailUIModel` for captures where feasible; the session LIST state may
   need a small additive seed hook (implementer's call, capture-tier only).

---

## 9. MCP tool specs (`mcp-server/src/server.ts`; tools 136 → 140)

Four passthroughs beside the existing `ai_copilot_*` block (~line 5960), zod
schemas, `toToolResult(() => bridge.send(...))`:

| Tool | Params | Bridges to | Description essentials |
|---|---|---|---|
| `ai_copilot_chats` | — | `ai.copilotChats` | list saved conversations in the OPEN project (they live in the project file); `active`, `droppedEntries` semantics; sorted newest-first |
| `ai_copilot_resume_chat` | `chatId: string (uuid)` | `ai.copilotResumeChat` | resume to continue with `ai_copilot_send`; current chat is archived first, never lost; fails with teaching error while a turn runs |
| `ai_copilot_delete_chat` | `chatId: string (uuid)` | `ai.copilotDeleteChat` | permanent — the only destructive chat verb |
| `ai_copilot_rename_chat` | `chatId: string (uuid)`, `title: string` | `ai.copilotRenameChat` | ≤120 chars, clamped |

Also: extend `ai_copilot_state`'s description with the additive
`chatId`/`chatTitle`/`droppedEntries` fields, and `ai_copilot_reset`'s with
"archives (does not destroy); returns archivedChatId/evictedChatId when
applicable". Update the npm test suite's tool-count/registration assertions.

---

## 10. Failure modes

- **Autosave mid-turn** → L3 snapshot (partials dropped, history as of last
  completed round). A crash-recovered chat reads as a consistent prefix, idle.
- **Crash between turn-end and next autosave tick** → up to ~30 s of chat lost —
  exactly the guarantee musical edits already have. Honest, accepted.
- **Flush failure during open/new** → open aborts, `.unsavedChanges`, engine
  untouched (§4.5 ordering makes this automatic — no pre-archive to unwind).
- **Corrupt/hand-edited chat in project.json** → lossy decode skips it with an
  open warning (§3.1); a chat with broken tool pairing resumes display-only with
  fresh provider context (§5.3); a provider 400 on anything that slips through
  surfaces as the turn's normal `.failure` entry — never a crash, never a loop.
- **Old build re-saves a new file** → chats dropped (stated, §3.2).
- **Eviction/truncation** → always surfaced (`evictedChatId`, `droppedEntries`,
  UI banner) — L6.
- **project.open/new/recover during a running turn** → boundary handler cancels;
  §5.4 generation guard guarantees no stale tool dispatch lands on the new
  project even in the cancellation window.
- **Feedback bundle** → chats excluded by construction (§4.3 privacy exception).

## 11. Risks found in current code (flagged for implementers)

1. **`reset()`-during-turn state pollution** — pre-existing bug, fix specced in
   §5.5 (catch-path `turnID` guard). Ship with Phase B + regression test.
2. **`trimHistory` + resume**: restored history must satisfy trim's invariants
   (head = plain user text; pairs unsplit) — enforced by
   `sanitizeProviderHistory` (§5.3), not assumed. `historyLimit` (20) already
   bounds what persists, so resume can never import an over-limit history.
3. **`stateJSON` compat**: all changes additive (§6.5); the `partial`-flag
   absent-when-false precedent is followed for `active`/`droppedEntries`.
4. **Recovery-bundle coverage**: rides `buildAutosaveDocument` automatically,
   BUT `writeFeedbackBundle` shares that builder — hence the `includeChats`
   parameter (§4.3). Do not forget it, or diagnostics bundles leak conversations.
5. **`autosaveTick` staleness token** only watches `lastEditEvent.seq` today —
   chat-only sessions would never crash-autosave without the `chatRevision`
   high-water extension (§4.4).
6. **DAWControlTests fixtures** construct store+router+engine by hand — the two
   new store closures (`copilotActiveChatProvider`, `copilotProjectBoundaryHandler`)
   must be wired in the shared test fixture too, or engine-loop tests will pass
   while the app path silently differs. Wire them in ONE bootstrap helper and
   call it from both `DAWProApp` init (~line 996–1015) and the fixtures.

## 12. Test plan (per module)

**DAWCoreTests** (new `CopilotChatPersistenceTests.swift`):
- `CopilotChatDocument` encode/decode round-trip (all entry kinds, all block types).
- `ProjectDocument`: absent key → nil → `[]`; empty chats → key omitted →
  pre-chat project re-save byte-identical; populated round-trip through
  `ProjectBundle.write`/`read`.
- Lossy decode: one corrupt chat element → others survive + dropped count.
- Store: archive upsert-by-id; eviction at 20 returns evicted id; take/remove/
  rename; `noteCopilotChatActivity` bumps revision + dirty.
- Dirty plumbing: chat-only dirty drives `autosaveIfNeeded` (titled + untitled),
  `flushForTransition`, and `autosaveTick` (chatRevision staleness: two ticks
  same revision = one write); save clears `chatsDirty`; `isDirty` untouched by
  chat mutations; no journal entry / no undo label change (L4).
- open/new/recover: chats swap correctly; `projectGeneration` bumps;
  recovered state is chat-dirty; feedback bundle excludes chats.

**DAWControlTests** (extend `CopilotEngineTests.swift`; new
`CopilotChatMappingTests.swift`; new `CopilotChatCommandTests.swift`):
- Mapping: L1 strip (assert NO `thinking` type and NO `signature`/rawJSON bytes
  in any persisted output), L2 placeholder for all-thinking assistant messages,
  L3 partial drop, caps + `droppedEntries` accumulation, unknown-kind skip,
  `sanitizeProviderHistory` (bad head / broken pairing → `[]`).
- Engine: reset archives + returns ids; reset on empty archives nothing;
  resume restores transcript+history and continues a turn against a
  FakeProvider (assert the provider request contains the restored messages);
  resume-while-running throws the exact teaching error; delete-active rules;
  projectDidTransition clears without archiving; §5.4 generation guard (open a
  new project mid-turn via fixture → no tool dispatch lands, turn cancelled);
  §5.5 regression (reset mid-await → state stays fresh-idle).
- Commands: four new commands' happy paths + every teaching error; reset/state
  additive fields present/absent correctly; `rejectUnknownKeys` on each;
  catalog exclusion (`CopilotCatalogTests` count bump).

**AIServicesTests**: no changes required (provider seam untouched); keep green.

**mcp-server (npm)**: four tool registrations, schema validation, bridge
call-through shapes, updated tool count.

**Manual/staging gate** (staging port 17695 laws apply): send → reset → chats →
resume → send continues context; save → reopen → chats listed → resume; kill -9
mid-conversation → relaunch → recover → chats present.

## 13. Phased implementation plan (agent routing)

| Phase | Scope | Files | Agent | Depends |
|---|---|---|---|---|
| **A — DAWCore persistence** | §3 DTOs+limits+LossyArray; §4 store state/methods/pathways/dirty/boundaries; AutosaveManager chat high-water | `Sources/DAWCore/CopilotChat.swift` (new), `ProjectDocument.swift`, `ProjectStore.swift`, `AutosaveManager.swift`; `Tests/DAWCoreTests/CopilotChatPersistenceTests.swift` (new) | swift-app-engineer (fable) | — |
| **B — Engine + mapping** | §5 lifecycle, mapping file, L1/L2/L3 laws, generation guard, §5.5 bug fix; bootstrap closure wiring (`DAWProApp.swift` ~996–1015 + willTerminate autosave call + shared test-fixture wiring) | `Sources/DAWControl/CopilotEngine.swift`, `Sources/DAWControl/CopilotChatMapping.swift` (new), `Sources/DAWApp/DAWProApp.swift`; `Tests/DAWControlTests/CopilotEngineTests.swift`, `CopilotChatMappingTests.swift` (new) | swift-app-engineer (fable) | A |
| **C — Wire + MCP** | §6 four commands + additive fields; `allCommands`; `CopilotToolCatalog.neverInclude`; `ExplainModel` entries; §9 MCP tools + npm tests; ARCHITECTURE command-count line | `Sources/DAWControl/Commands.swift`, `CopilotCatalog.swift`, `Sources/DAWAppKit/ExplainModel.swift`; `Tests/DAWControlTests/CopilotChatCommandTests.swift` (new); `mcp-server/src/server.ts` + tests | mcp-integration-engineer (sonnet) | B |
| **D — UI** | §8 requirements: session list, resume, title/rename, reset relabel, truncation banner, delete confirm | `Sources/DAWApp/Copilot/CopilotRailView.swift`, `Sources/DAWAppKit/CopilotRailUIModel.swift` (+ tests) | ui-design-engineer (fable) | C |
| **E — Docs** | ROADMAP tick, CHANGELOG, ARCHITECTURE "Key future decisions" flip to SETTLED-implemented + counts 137/140 | `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`, `CHANGELOG` | docs-scribe (haiku) | D |

Convention check per phase: every new capability = control command + MCP tool +
test (Phase C closes the loop for A/B). `./scripts/test.sh`, never bare
`swift test`. All wire/MCP changes additive-only; no live command renamed.

**Xcode requirement: none.** Pure SwiftPM/CLT throughout — no entitlements,
signing, or AUv3 surface is touched by any phase.

## 14. Invariants audit

- **Render thread**: untouched — everything here is MainActor/persistence-side;
  zero engine (`AudioEngineProtocol`) surface changes.
- **DAWCore headless & dependency-free**: new DTOs are pure Foundation Codable;
  the engine seam is closures, matching `instrumentStateProvider`.
- **One command surface**: chat list/resume/delete/rename are store+engine
  operations exposed on the wire; the UI reads the same state — nothing
  UI-only, everything agent-controllable.
