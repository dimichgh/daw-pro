# Design: Copilot Rail v1 (M6 rail-a)

In-app AI chat rail driving the DAW through the existing control-command dispatch, with per-turn session context. Design only; implementation split across rail-b/c/d.

## §1 Decisions table
| # | Decision | Status |
|---|---|---|
| D1 | Hand-curated `CopilotToolCatalog` in DAWControl, ~33 commands, exhaustiveness-tested against `CommandRouter.allCommands`. No auto-derivation (no Swift schema registry exists; JSON schemas live only in mcp-server/src/index.ts). Author catalog schemas by transliterating the matching mcp-server tool schemas. | CONFIRMED |
| D2 | In-process execution through `CommandRouter.handle(_ request: ControlRequest) async -> ControlResponse` (@MainActor, Commands.swift:204) — the exact entry `ControlServer.dispatch` uses (ControlServer.swift:87-98). No loopback self-connection. Tests drive the real router over a store with no audio engine attached (DAWControlTests precedent). | CONFIRMED |
| D3 | Context block rebuilt every turn from ProjectStore; ~2000-token cap; 8-char UUID prefixes with an engine-side expansion map. Commands require full UUID strings (`params.require(_, \.stringValue)` + `UUID(uuidString:)`), so the engine re-expands prefixes in tool-call args before dispatch. | CONFIRMED |
| D4 | `CopilotEngine` lives in **DAWControl**, not AIServices. Rationale: DAWControl already imports AIServices (Package.swift:47); the engine must hold `CommandRouter` + `JSONValue` (DAWControl types), so AIServices placement is a dependency cycle. AIServices keeps `CopilotProviding` + HTTP clients. DAWCore stays AI-free either way. Engine is `@MainActor @Observable`; DAWApp views observe it directly (DAWAppKit does not import DAWControl, and a thin transcript rail needs no mirror view-model). | AMENDED |
| D5 | `CopilotProviding` protocol in AIServices; non-streaming v1; `resolveCopilotProvider(environment:store:)` chain in the exact style of `resolveLyricsWriter` (Anthropic preferred, OpenAI fallback, actionable no-key error naming Settings ⌘,). Raw URLSession, stub-HTTP wire-shape tests, keys never logged. | CONFIRMED |
| D6 | `ai.copilotSend` {message}→{turnId}, `ai.copilotState` {turnId?}→transcript/status (poll precedent: `ai.generationStatus`), `ai.copilotReset`. All three in `allCommands` + MCP tools (88→91). Not debug-tier: external-agent-drives-copilot is a legitimate composed surface. Recursion is impossible by construction: the catalog excludes `ai.copilot*`, asserted by test. | CONFIRMED |
| D7 | Catalog is a positive allow-list (~33 entries). A `neverInclude` denylist {project.new, project.open, project.save, track.remove, ai.copilotSend, ai.copilotState, ai.copilotReset} is asserted disjoint from the catalog by test, so future growth cannot re-add them. Also omitted (not denylisted): transport.record / track.setArm (live capture + mic-permission prompts stay human-initiated in v1), input.*/midi.* device switching, fx.*/automation.*/groove.* (v1.1 candidates, keeps v1 ≤ ~35). Everything included is an undoable ProjectStore edit or read-only. Runaway guards: 8 tool rounds/turn, per-result size cap, 20-message history window. | CONFIRMED (list refined) |
| D8 | Four suites: engine unit (FakeCopilotProvider scripts tool-call sequences against the REAL CommandRouter), catalog exhaustiveness, `ai.copilot*` command wire tests, stub-HTTP provider shape tests. Counts in §8. | CONFIRMED |

## §2 Types & signatures

### AIServices (new file `Sources/AIServices/CopilotProvider.swift`)
AIServices cannot see DAWControl's `JSONValue`, so the provider seam speaks pre-encoded `Data` for schemas/tool inputs (Sendable, no new JSON type, no duplication):

```swift
public struct CopilotToolSpec: Sendable, Equatable {
    public var name: String          // wire name, dots mapped to underscores (see §3)
    public var description: String
    public var inputSchemaJSON: Data // JSON Schema object, pre-encoded by the catalog
}

public enum CopilotContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: Data)
    case toolResult(id: String, content: String, isError: Bool)
}

public struct CopilotMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var blocks: [CopilotContentBlock]
}

public struct CopilotTurnRequest: Sendable {
    public var system: String              // system prompt + session context (§4)
    public var messages: [CopilotMessage]  // trimmed history, tool pairs intact
    public var tools: [CopilotToolSpec]
    public var maxTokens: Int              // default 4096
}

public struct CopilotReply: Sendable, Equatable {
    public enum StopReason: Sendable, Equatable { case endTurn, toolUse, maxTokens, other(String) }
    public var blocks: [CopilotContentBlock]  // text and/or toolUse blocks
    public var stopReason: StopReason
    public var provider: String                // "anthropic" | "openai"
}

public protocol CopilotProviding: Sendable {
    func complete(_ request: CopilotTurnRequest) async throws -> CopilotReply
}

/// Anthropic preferred, OpenAI fallback, else AIServiceError.noProviderConfigured
/// (capability: "copilot") — same chain + actionable Settings (⌘,) message as
/// resolveLyricsWriter (Providers.swift:239).
public func resolveCopilotProvider(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?,
    config baseConfig: AIConfig = AIConfig()
) throws -> any CopilotProviding
```

`AnthropicCopilotProvider` / `OpenAICopilotProvider`: structs holding `AIConfig`; POST `{anthropicBaseURL}/v1/messages` (model `config.anthropicModel`, currently "claude-sonnet-5" per AIConfig.swift:31) / `{openAIBaseURL}/v1/chat/completions`. Raw URLSession, keys in headers only (`x-api-key` + `anthropic-version: 2023-06-01`; `Authorization: Bearer`), bodies never logged. OpenAI adapter translates blocks: assistant toolUse → `tool_calls`, toolResult → role:"tool" messages.

### DAWControl (new files `CopilotCatalog.swift`, `CopilotEngine.swift`)

```swift
/// One catalog entry. `command` is the canonical control-protocol name
/// ("clip.addMIDI"); `spec()` derives the wire CopilotToolSpec, mapping
/// "." → "_" (Anthropic/OpenAI tool names forbid dots; commands contain no
/// underscores, so the reverse map "_" → "." is unambiguous — asserted by test).
public struct CopilotTool: Sendable {
    public var command: String
    public var description: String
    public var schema: JSONValue      // JSON Schema as a JSONValue object
    public func spec() -> CopilotToolSpec
}

public enum CopilotToolCatalog {
    public static let v1: [CopilotTool]          // §3 list
    public static let neverInclude: Set<String>  // §7 denylist, test-asserted
}

@MainActor @Observable
public final class CopilotEngine {
    public enum TurnStatus: String, Sendable { case idle, running, done, failed, cancelled }

    public struct TranscriptEntry: Identifiable, Sendable {
        public enum Kind: Sendable {
            case user(String)
            case assistant(String)
            case toolCall(command: String, argsSummary: String)
            case toolResult(command: String, ok: Bool, summary: String)
            case failure(String)   // provider/turn-level error, actionable text
        }
        public let id: UUID
        public let turnID: String
        public let kind: Kind
    }

    public private(set) var transcript: [TranscriptEntry] = []
    public private(set) var status: TurnStatus = .idle
    public private(set) var currentTurnID: String?

    public init(
        store: ProjectStore,
        dispatch: @escaping @MainActor (ControlRequest) async -> ControlResponse,
        provider: (@MainActor () throws -> any CopilotProviding)? = nil, // default: resolveCopilotProvider over shared key chain, resolved PER TURN (keys added mid-session take effect — lyricsWriterProvider precedent, Commands.swift:69)
        catalog: [CopilotTool] = CopilotToolCatalog.v1,
        maxToolRounds: Int = 8,
        historyLimit: Int = 20
    )

    @discardableResult public func send(_ message: String) throws -> String  // turnId; throws if a turn is running
    public func cancel()   // cancels the in-flight turn Task
    public func reset()    // clears transcript + history; no-op cancel if running
    public func stateJSON(turnID: String?) -> JSONValue  // ai.copilotState payload
}
```

Wiring (two-phase, no retain cycle): `CommandRouter` gains `public weak var copilotEngine: CopilotEngine?` (the `appCommandHandler` install precedent, Commands.swift:82). DAWApp (and tests) construct `router`, then `engine = CopilotEngine(store:dispatch: { await router.handle($0) })` (closure strongly captures router — fine, router only holds the engine weakly), then `router.copilotEngine = engine`, and RETAIN the engine (app state / test local). `ai.copilot*` cases route through the weak ref and throw an actionable "copilot not wired" ControlError when nil.

## §3 Tool catalog

36 commands, positive allow-list. Wire tool names map "." → "_" ("clip.addMIDI" → "clip_addMIDI"); command names contain no underscores, so reverse mapping is unambiguous (test-asserted). NOTE: these wire names intentionally differ from mcp-server snake_case names ("track_add_send") — the copilot never talks to the MCP server, so no parity requirement exists; only catalog↔allCommands parity matters.

| Family | Commands | Notes |
|---|---|---|
| transport (6) | play, stop, seek, setTempo, setLoop, setMetronome | setPunch/record omitted (§7) |
| track (7) | add, rename, setVolume, setPan, setMute, setSolo, setInstrument | remove denylisted; setOutput/sends v1.1 |
| clip (9) | addAudio, addMIDI, setNotes, move, trim, split, remove, setGain, stretchToLength | setFades/quantize* v1.1; clip.remove is an undoable edit — allowed |
| take (2) | select, flatten | setComp v1.1 (comp-segment JSON too fiddly for v1) |
| mixer (1) | setMasterVolume | |
| render (2) | mixdown, measureLoudness | bounce/stems v1.1 |
| ai (6) | sidecarStart, generateSong, generationStatus, importGeneration, fixClipRegion, importClipFix | the full generate→poll→import loop + clip-fix loop |
| discovery (2) | project.snapshot, instrument.listAudioUnits | snapshot result size-capped (§7); listAudioUnits needed so setInstrument gets valid component IDs |
| edit (1) | undo | redo v1.1; "undo that" is a natural rail request |

Authoring: each `CopilotTool.description` and `schema` is transliterated from the matching tool in `mcp-server/src/index.ts` (75 inputSchemas exist there — the only JSON-schema source in the repo), tightened to ~1-2 sentences. Schemas are `JSONValue.object` literals with `"type": "object"`, `"properties"`, `"required"`.

Exhaustiveness test asserts: (a) every catalog command ∈ `CommandRouter.allCommands`; (b) catalog ∩ `neverInclude` = ∅; (c) no duplicate commands; (d) wire-name mapping round-trips bijectively; (e) every schema is an object schema; (f) no catalog command starts with "debug." or "ai.copilot".

## §4 Session context

AMENDED vs. brief: "selection" is dropped — ProjectStore has no selection concept (only `selectedInputDeviceUID`, an audio-input device, ProjectStore.swift:35); UI selection lives in app-side view models off the command surface. Everything else as proposed.

Rebuilt from ProjectStore at the START OF EVERY PROVIDER ROUND (not just per turn — mid-turn tool calls mutate the project and the model must see results), appended to the system prompt. Plain text:

```
PROJECT: "<projectName>"<" (unsaved changes)" if isDirty>
TRANSPORT: <tempoBPM> BPM <timeSignature> | <stopped|playing|recording> @ beat <positionBeats> | loop <off|START-END> | metronome <on|off>
MASTER: volume <masterVolume>
UNDO: <undoLabel ?? "nothing to undo"> / redo: <redoLabel ?? "-">
TRACKS (<n>):
- [<id8>] "<name>" <kind><" (AI)" if isAIGenerated> | vol <v> pan <p><" MUTED"><" SOLO"> | <clipCount> clips
    clips: [<id8>] "<name>" @ <startBeat>..<endBeat><" (AI)">; ... (max 8, then "+N more")
    takes: [<id8>] "<groupName>" <laneCount> lanes, <compSegmentCount> comp segments
(max 24 tracks, then "+N more tracks")
```

Caps: whole block hard-capped at 8,000 chars (~2,000 tokens; no tokenizer dependency — character proxy, stated in code comment). Truncation appends "[context truncated — use project.snapshot for detail]".

ID policy: `[id8]` = first 8 lowercase hex chars of the UUID. The builder returns `(text: String, idMap: [String: UUID])`; the engine keeps the latest map. On prefix collision (two UUIDs sharing 8 chars): colliding entries print their full UUIDs and stay OUT of the map. Expansion before dispatch: for each TOP-LEVEL string param whose key hasSuffix "Id"/"ID" AND whose value is a key in idMap, replace with the full UUID string; values already parsing as full UUIDs pass through; `jobId` explicitly exempt (sidecar job ids are not project UUIDs). Nested expansion is not needed in v1 — no catalog command carries ids below top level (take.setComp would; it is excluded). CONFIRMED necessary: id params go through `params.requireTrackID()`-family helpers (Commands.swift:2737-2793) which do `UUID(uuidString:)` on the full string — an 8-char prefix would be rejected.

Context builder lives in `CopilotEngine.swift` as `static func buildContext(store: ProjectStore) -> (text: String, idMap: [String: UUID])` — pure @MainActor function, directly unit-testable.

## §5 Engine turn loop

`send(message)` — synchronous part (so `ai.copilotSend` fails fast):
1. Throw `ControlError` if `status == .running` ("a copilot turn is already running — poll ai.copilotState, or ai.copilotReset").
2. Resolve the provider NOW via the injected factory (default: `resolveCopilotProvider` over the shared env+Keychain chain, per-turn like `lyricsWriterProvider`, Commands.swift:69). `noProviderConfigured` propagates synchronously → `ai.copilotSend` returns the actionable Settings (⌘,) error immediately.
3. `turnID = UUID().uuidString`, `status = .running`, append `.user` transcript entry, append user `CopilotMessage` to history, store and start the turn `Task` (@MainActor), return turnID.

Turn `Task` body — up to `maxToolRounds` (8) provider rounds:
1. Rebuild session context + idMap from the store (fresh EVERY round — tool calls mutate the project mid-turn).
2. `provider.complete(CopilotTurnRequest(system: fixedSystemPrompt + context, messages: trimmedHistory, tools: catalog specs, maxTokens: 4096))`. Await hops off-main inside the provider (nonisolated Sendable); engine state is touched only on MainActor. `try Task.checkCancellation()` after.
3. Append the reply's blocks to history as ONE assistant `CopilotMessage`. Transcript: text blocks → `.assistant`; toolUse blocks → `.toolCall(command, argsSummary ≤300 chars)`.
4. No toolUse blocks → `status = .done`, stop.
5. Else execute toolUse blocks SEQUENTIALLY in block order:
   - Reverse-map wire name ("_" → "."); name not in the catalog (model hallucination) → tool_result `isError: true` "unknown tool <name>" WITHOUT dispatching (the catalog is the gate, not allCommands).
   - Decode `inputJSON` → `[String: JSONValue]` (JSONValue is Codable); undecodable input → error tool_result, no dispatch.
   - Expand id prefixes (§4), build `ControlRequest(id: "copilot-<turnID>-r<round>-<i>", command:, params:)`, `await dispatch(request)`.
   - `ok` → content = JSON-encoded result capped at 4,000 chars ("[truncated]" marker), `isError: false`; `!ok` → content = error string, `isError: true` — command errors go BACK TO THE MODEL as tool results (it reacts/repairs; ControlError messages are already agent-actionable), they do not abort the turn.
   - Append `.toolResult` transcript entry. Collect all results into ONE user `CopilotMessage` of toolResult blocks (Anthropic requires tool_result in the immediately-next user message, ids matched).
6. Rounds exhausted while the model still wants tools → append `.failure("tool-round limit (8) reached — partial work applied (each step is undoable); send a follow-up to continue")`, `status = .done` (work done is real; not a failure state).
7. `catch is CancellationError` → `status = .cancelled` + `.failure("cancelled")`. `catch` other → `status = .failed` + `.failure(localizedDescription)` — provider errors are already key-free (AIServiceError, AIConfig.swift:104-118).

History trimming: keep the last `historyLimit` (20) `CopilotMessage`s, trimmed only at exchange boundaries — drop oldest whole (user → assistant[→toolResults…]) groups so the head is always a plain user text message and tool_use/tool_result pairs never split (Anthropic 400s otherwise). Transcript (UI/state surface) is unbounded until `reset()`.

`cancel()`: `turnTask?.cancel()` — takes effect at the next round boundary or inside the provider's URLSession await (cancellation-aware); an in-flight command dispatch is never interrupted mid-edit. `reset()`: cancel + clear transcript/history/idMap, `status = .idle`.

Fixed system prompt (short, in `CopilotEngine.swift`): role ("you are the copilot inside DAW Pro, operating the running project via tools"), beats-not-seconds convention, "every tool edit is undoable; for destructive/global actions you lack tools for (deleting tracks, opening/saving projects), tell the user what to click instead", id-prefix convention, "prefer few precise tool calls".

## §6 Wire & MCP surface

Three new commands in `CommandRouter.allCommands` (86 → 89) + `route(_:)` cases delegating to the weak `copilotEngine` (nil → ControlError "copilot engine not wired — app startup incomplete"):

| Command | Params | Result | Errors |
|---|---|---|---|
| `ai.copilotSend` | `message` string, required non-empty | `{turnId, status: "running"}` | turn already running; no provider key (actionable ⌘, message); engine not wired |
| `ai.copilotState` | `turnId` string optional (filter; omit = whole session) | `{status, currentTurnId?, transcript: [{id, turnId, kind, text?, command?, ok?, summary?}]}` | engine not wired |
| `ai.copilotReset` | — | `{}` | engine not wired |

Poll flow mirrors `ai.generateSong`/`ai.generationStatus` (Commands.swift:1328/1366): send returns immediately, poll state until `status` ∈ {done, failed, cancelled}. Params validated with the existing `params.require(_, \.stringValue)` idiom.

MCP (mcp-server/src/index.ts): three tools `ai_copilot_send`, `ai_copilot_state`, `ai_copilot_reset` (naming precedent `ai_sidecar_status`), thin bridges over the WebSocket like every other tool; MCP tool count 88 → 91, `/mcp-verify` parity holds. Each description carries the recursion caveat: "Drives the IN-APP copilot, which executes DAW commands itself. Prefer direct tools for direct edits; use this to delegate a whole musical task or to test the copilot. The copilot cannot call itself (its catalog excludes ai.copilot*)." Depth is 1 by construction: MCP → copilot → in-process dispatch; the engine's dispatch closure goes straight to `router.handle`, never through the socket.

## §7 Safety rails

- **Allow-list**: only the 36 §3 commands are ever visible to the model or dispatchable by the engine — unknown/hallucinated names bounce as error tool_results without touching the router.
- **Denylist** `CopilotToolCatalog.neverInclude = {project.new, project.open, project.save, track.remove, ai.copilotSend, ai.copilotState, ai.copilotReset}` — asserted disjoint from the catalog by test so future catalog growth cannot re-add them. `project.save` added beyond the brief (one line: file-system overwrites stay human-initiated in v1; the copilot proposes, the human clicks — same policy as project.new/open). Omitted-not-denylisted (v1.1 candidates or human-initiated): transport.record, transport.setPunch, track.setArm (live capture + mic-permission prompts), track.setOutput/sends, input.*/midi.*, fx.*, automation.*, groove.*, take.group/setComp/removeLane/move/setCrossfade/autoAlign, clip.setFades/setStretch/quantize/detectTransients/quantizeAudio, render.bounce/stems, ai.sidecarStatus/Stop, ai.extractStems, ai.legoGenerate, ai.importGeneratedStems, ai.repaintAudio, ai.writeLyrics, ai.providerStatus, edit.redo, project.snapshot-adjacent debug.*.
- **Undo story**: every allowed mutation is an undoable ProjectStore edit — the human can step back through each copilot action individually; the copilot itself has `edit.undo` for "undo that".
- **Runaway guards**: 8 tool rounds/turn; one turn at a time (send throws while running); 4,000-char tool-result cap; 8,000-char context cap; maxTokens 4096; 20-message history window; 300-char transcript arg summaries.
- **Key hygiene**: keys exist only inside provider clients as HTTP headers, resolved per turn via the shared `resolveKey` chain; the engine, transcript, `ai.copilotState` payloads, and logs never carry key material; the no-key error is the key-free actionable `noProviderConfigured` message.
- **Network**: no new listening surface (engine is in-process; control plane stays loopback-only ws://127.0.0.1:17600); provider traffic is outbound HTTPS to `AIConfig` base URLs only (stub tests retarget to loopback).
- **RT audio**: nothing here touches the render thread — all engine work is @MainActor + URLSession; command dispatch is the same main-actor path the WebSocket already uses. No new allocation/locking risk.
- **UI identity**: rail-d renders all copilot output with the violet AI identity per docs/DESIGN-LANGUAGE.md; material created via ai.importGeneration/importClipFix already carries `isAIGenerated`.

## §8 Test plan

All key-less; run via `./scripts/test.sh`. One §2 addendum surfaced here: `CopilotEngine` gains `public func waitForTurn() async` (awaits the stored turn Task) so tests — and rail-d if it wants — get deterministic completion without polling.

**Suite A — `Tests/AIServicesTests/CopilotProviderTests.swift` (~12 tests)**
Stub-HTTP precedent: LyricsWriterTests.swift (loopback stub server, `AIConfig` base-URL retarget).
- `resolveCopilotProvider`: Anthropic key → Anthropic; OpenAI-only → OpenAI; neither → `noProviderConfigured("copilot")` containing "Settings" and "⌘," (3).
- Anthropic wire shape: body pins model/max_tokens/system/`tools[].{name,description,input_schema}`/message roles + tool_use/tool_result block serialization with matched ids; headers `x-api-key` + `anthropic-version`; reply parse (text + tool_use + stop_reason map); HTTP-4xx → `requestFailed`; garbage body → `malformedResponse` (6).
- OpenAI translation: toolUse → `tool_calls`, toolResult → role "tool", args JSON round-trip, finish_reason map (3).

**Suite B — `Tests/DAWControlTests/CopilotCatalogTests.swift` (~7 tests)**
§3 assertions (a)-(f) plus: neverInclude ∩ catalog = ∅; every schema is `"type":"object"` with properties; wire-name bijection over the full catalog.

**Suite C — `Tests/DAWControlTests/CopilotEngineTests.swift` (~14 tests)**
`FakeCopilotProvider` (scripted `[CopilotReply]`, records every `CopilotTurnRequest`) + REAL `CommandRouter` over a real `ProjectStore` with no audio engine (ControlTests precedent); dispatch closure = `{ await router.handle($0) }`.
- text-only reply → transcript user+assistant, status done.
- one tool round (`track_add`) → track actually exists in `store.tracks`; result content fed back as tool_result.
- multi-round chain (add track → add MIDI clip) → round-2 recorded `system` contains the new track's 8-char prefix (proves per-round context rebuild).
- id-prefix expansion: scripted `track_setVolume` with prefix arg mutates the right track.
- command error → next request carries `isError: true` tool_result with the ControlError text.
- hallucinated tool name → error tool_result, no router call (assert store untouched).
- denylisted name (`track_remove`) → unknown-tool path (not in catalog ⇒ never dispatched).
- round-limit exhaustion → status done + limit `.failure` entry.
- send-while-running throws; cancel → `.cancelled`; reset clears transcript+history.
- provider factory throws → `send` throws the actionable message synchronously.
- history trimming at exchange boundaries (head is plain user text; no orphan tool_result).
- oversized tool result truncated at 4,000 chars with marker.

**Suite D — `Tests/DAWControlTests/CopilotCommandTests.swift` (~8 tests)**
Through `router.handle` (wire level): copilotSend returns turnId then `waitForTurn` + copilotState shows done transcript; send during running turn → error; engine-not-wired → actionable error; state turnId filter; state omitted-turnId full session; reset cancels+clears; missing `message` param → require error; no-key path surfaces ⌘, message.

Rough total: ~41 new tests (baseline 1171 → ~1212).

## §9 File checklist & write order

**rail-b — provider client (AIServices only; buildable + testable standalone):**
1. `Sources/AIServices/CopilotProvider.swift` — §2 types, `CopilotProviding`, `resolveCopilotProvider`, `AnthropicCopilotProvider`, `OpenAICopilotProvider` (raw URLSession, `AIConfig` base URLs/models).
2. `Tests/AIServicesTests/CopilotProviderTests.swift` — Suite A.

**rail-c — engine + wire (DAWControl + app wiring + MCP + docs):**
1. `Sources/DAWControl/CopilotCatalog.swift` — `CopilotTool`, `CopilotToolCatalog.v1` (§3, schemas transliterated from `mcp-server/src/index.ts`), `neverInclude`, wire-name mapping helpers.
2. `Sources/DAWControl/CopilotEngine.swift` — engine (§2/§5), `buildContext` (§4), system prompt.
3. `Sources/DAWControl/Commands.swift` — 3 entries in `allCommands`, 3 `route` cases, `public weak var copilotEngine`.
4. `Sources/DAWApp/DAWProApp.swift` — wire at the router construction site (line ~288): build engine with `dispatch: { await router.handle($0) }`, retain it in app state, assign `router.copilotEngine`.
5. `mcp-server/src/index.ts` — `ai_copilot_send` / `ai_copilot_state` / `ai_copilot_reset` (88 → 91 tools; run `/mcp-verify`).
6. `Tests/DAWControlTests/CopilotCatalogTests.swift`, `CopilotEngineTests.swift`, `CopilotCommandTests.swift` — Suites B/C/D.
7. Docs: check rail-b/rail-c boxes in `docs/ROADMAP.md` (and edit the rail-c line — no `DAWAppKit.CopilotModel`, see §10); move this design doc to `docs/research/design-rail-a-copilot.md`; settle the copilot-placement entry under `docs/ARCHITECTURE.md` "## Key future decisions" (line 67).

**rail-d — rail UI (DAWApp only):**
1. `Sources/DAWApp/Copilot/CopilotRailView.swift` (+ small subviews in the same directory) — docked right-side rail, violet AI identity per `docs/DESIGN-LANGUAGE.md`, transcript with tool-action chips (toolCall/toolResult entries), input field, running shimmer, cancel/reset controls. Observes `CopilotEngine` directly (`@Observable`; DAWApp imports DAWControl). Progress affordance v1 = transcript entries appearing per round (engine appends mid-turn) — no token streaming.
2. `Sources/DAWApp/ContentView.swift` — mount the rail (toggleable panel).
3. Verification: `debug.captureUI` captures + orchestrator design review (roadmap rail-d), plus an app-level smoke that the rail renders with a fake-provider engine.

No Xcode-only requirements anywhere in rail-b/c/d: no entitlements, no AUv3, no signing — SwiftPM + Command Line Tools suffice. (Outbound HTTPS in rail-e real-key gate needs no entitlement in a non-sandboxed dev run.)

## §10 Sub-item boundaries

- **rail-b** CONFIRMED as scoped: pure AIServices, zero DAWControl edits, key-less stub tests. Dependency-free of rail-c (protocol defined provider-side).
- **rail-c** AMENDED: delivers `CopilotEngine` in DAWControl as THE headless model — the roadmap's "`DAWAppKit.CopilotModel`" is dropped. Rationale: DAWAppKit does not (and should not need to) import DAWControl; the engine is already headless, `@Observable`, and fully testable in DAWControlTests; a mirror view-model would duplicate transcript state with no logic of its own. Roadmap line to be edited when rail-c lands. Everything else (conversation store, same-dispatch execution, ai.copilot* commands + MCP tools, fake-provider round-trips) stays in rail-c as written.
- **rail-d** CONFIRMED: pure DAWApp SwiftUI over the observable engine; "streaming" affordance interpreted as per-round transcript growth (non-streaming provider v1 per D5).
- **rail-e** unchanged: real-key gate (BLOCKED on ANTHROPIC_API_KEY/OPENAI_API_KEY per ROADMAP "## Blocked"); one real conversation driving actual edits, then check the parent box.
- Sizing: rail-b ≈ 1 file + 1 suite; rail-c ≈ 3 source files + 3 suites + wiring + MCP + docs (the largest — if it overruns, split MCP tools + docs into a trailing micro-task); rail-d ≈ 2 files + captures. Each fits one agent-cycle.

## §11 Edge cases

1. **Empty/blank message** → `ai.copilotSend` rejects via require + non-empty check (ControlError), no turn spawned.
2. **Provider returns zero blocks** (stop endTurn, empty content) → treat as done with a synthetic assistant entry "(no response)"; never loop.
3. **Provider returns tool_use with stopReason endTurn** (inconsistent) → trust blocks over stopReason: execute tools, continue.
4. **Model emits multiple tool_use blocks in one reply** → execute sequentially in order; all results in one following user message (Anthropic contract).
5. **8-char arg matches no map entry but parses as full UUID** → pass through untouched; matches neither → pass through and let the command's own require/UUID validation produce the actionable error, which returns to the model as a tool_result.
6. **Prefix collision** → colliding ids printed full-length in context and excluded from the map (§4); model uses full ids for those.
7. **Project mutated by the human mid-turn** (UI click while copilot runs) → harmless: both paths are @MainActor-serialized single edits; next round's context rebuild sees the new state.
8. **`ai.generateSong` long jobs**: the copilot submits and can poll `ai_generationStatus` a round or two, but 8 rounds won't cover minutes-long jobs — system prompt instructs: submit, report the jobId, tell the user to ask again later (or the user re-sends "import it now"); context is stateless so a later turn imports fine.
9. **render.mixdown mid-turn cancellation** → dispatch is never interrupted; cancel lands after the command returns; document in cancel() comment.
10. **Keys added mid-session** (Settings ⌘,) → next `send` re-resolves the provider (per-turn factory), no restart needed — lyricsWriterProvider precedent.
11. **Engine deallocated with turn in flight** (tests) → turn Task holds `[weak self]` for engine-state writes; dispatch closure may retain the router until the round completes, then the task ends — no crash, no leak.
12. **ai.copilotState with unknown turnId** → `{status: current, transcript: []}` (empty filter result, not an error — poller-friendly).
13. **Undo of copilot edits collapses?** No — each command is its own journal entry; a 6-call turn = 6 undo steps. v1.1 candidate: batch a turn into one named undo group; flagged for ARCHITECTURE "Key future decisions", NOT in v1 (ProjectStore has no grouping primitive today).
14. **Transcript growth over a long session** → unbounded until reset by design (UI needs scrollback); entries are small (caps in §7); `ai.copilotState` full-session response stays modest; revisit only if a real session shows >1 MB payloads.

---
Verified sources: Package.swift (target graph), Sources/DAWControl/Commands.swift (router, allCommands, validation), Sources/DAWControl/ControlServer.swift (dispatch path), Sources/AIServices/Providers.swift, Sources/AIServices/KeyStore.swift, Sources/DAWAppKit/LyricsWorkshopModel.swift, docs/ARCHITECTURE.md.
---
