# m23-dl (model lifecycle manager) — wire recon

Read-only recon. Task context: implement a model-lifecycle manager for the ACE-Step
sidecar (and possibly RVC / Whisper) — auto-idle/unload after N minutes of no use,
building on the existing `SidecarStopPlanner.swift` mechanism from m23-bb.

## 1. Sidecar command surface (ACE + RVC)

### `allCommands` entries (Sources/DAWControl/Commands.swift)
```
274: "ai.sidecarStatus",
275: "ai.sidecarStart",
276: "ai.sidecarStop",
...
325: "vc.sidecarStatus",
326: "vc.sidecarStart",
327: "vc.sidecarStop",
```

### ACE handlers — `Sources/DAWControl/Commands.swift`
- `case "ai.sidecarStatus":` line 3154. No params (`rejectUnknownKeys([], verb:)` at 3178).
  Calls `await sidecarManager.status()` (3179), returns the `SidecarStatus` Codable
  (AIServices) as-is: `{state, message, version?, ditModel?, lmModel?, pid?, phase?,
  startingForSeconds?}`. `state` ∈ notInstalled/installedNotRunning/starting/healthy/error.
  `phase`/`startingForSeconds` (M10-b) populated only when state == "starting", tracked
  across the WHOLE boot via a pidfile-liveness fallback (survives app relaunch mid-boot).
- `case "ai.sidecarStart":` line 3182. No params. Calls `try await sidecarManager.start()`
  (3198) — spawns `scripts/ace-step/run.sh`, polls `/health` up to ~30s. A timeout without
  reaching healthy is NOT an error — returns state "starting". Throws `notInstalled` if
  never installed.
- `case "ai.sidecarStop":` line 3201. No params (m16-e). Calls `try await
  sidecarManager.stop()` (3217) — graceful SIGTERM escalating to SIGKILL, targets either
  the pidfile process (if live) or whoever holds the listening socket (m23-bb fix for
  stale-pidfile false "was not running"). No-op success if not running. Throws
  `SidecarError.stopFailed` if still answering afterwards or if the port-holder can't be
  identified as ACE-Step.

Handler backing type: `sidecarManager` — `Sources/AIServices/SidecarManager.swift`
(actor/class wrapping the ACE-Step sidecar lifecycle; loopback 127.0.0.1:8001).
Status model: `Sources/AIServices/SidecarStatus.swift`.

### The FULL `ai.*`/`vc.*` case list, and — critically — which injected dependency each routes through

`grep -n 'case "ai\.\|case "vc\.' Sources/DAWControl/Commands.swift` → 32 cases total.
Recorded here because §1's original pass only covered the sidecarStatus/Start/Stop
trio + vc twin, and the ACTIVITY surface (what tells a lifecycle manager "the model
was just used") is a DIFFERENT set of commands and — structurally important —
**a different injected dependency than `sidecarManager`**:

```
ai.sidecarStatus / ai.sidecarStart / ai.sidecarStop   → sidecarManager: SidecarManaging
ai.providerStatus                                      → keyStore/keyEnvironment (unrelated)
ai.writeLyrics                                          → lyricsWriterProvider (Anthropic/OpenAI, unrelated to ACE)
ai.generateSong                                         → songGenerator.generateSong(...)
ai.generationStatus                                     → songGenerator.generationStatus(jobID:)
ai.importGeneration                                     → store.importGeneration(...) (uses store.generationSource, wraps songGenerator)
ai.extractStems                                         → songGenerator.extractStems(...)
ai.legoGenerate                                         → songGenerator.generateLegoTracks(...)
ai.importGeneratedStems                                 → store.importGeneratedStems(...)
ai.repaintAudio                                         → songGenerator.repaintAudio(...)
ai.fixClipRegion                                        → store.fixClipRegion(...)
ai.importClipFix                                        → (store-side, completes the fixClipRegion flow)
ai.copilotSend/State/Reset/GetModel/SetModel/Chats/...  → copilot chat plumbing, unrelated
vc.sidecarStatus / vc.sidecarStart / vc.sidecarStop     → voiceConversionManager: VoiceConversionManaging
vc.convertVocals                                        → store.voiceConversionSource(...) (wraps voiceConverting)
vc.listVoices                                           → voiceConverting.availableVoiceTargets(...)
vc.trainVoice                                            → voiceConverting.train(...)
ai.installSpeechModel / ai.speechModelInstallStatus     → installCoordinator (WhisperModelInstallCoordinator)
```

**This is the single most important structural finding for m23-dl's design.** The
lifecycle/health trio (`sidecarManager`) and the actual GENERATION traffic
(`songGenerator: SongGenerating`, concretely `ACEStepClient`) are TWO SEPARATE Swift
objects with NO shared state, injected independently in `CommandRouter.init` (lines
404-448: `sidecarManager: SidecarManaging = SidecarManager()`, `songGenerator:
SongGenerating = ACEStepClient()`). Confirmed by reading `ACEStepClient.Configuration`
(`Sources/AIServices/ACEStepClient.swift:712,730`): it has its OWN `baseURL: URL`
defaulting independently to `http://127.0.0.1:8001` — same port as `SidecarManager`,
but a completely separate HTTP client instance. **An idle-tracker hung only off
`SidecarManager` (the natural first instinct, since that's "the sidecar lifecycle
object") is structurally BLIND to the only activity that actually matters** — a
generation job running via `songGenerator` would never be observed by anything
watching only `sidecarManager`. The RVC twin is the same shape:
`voiceConversionManager: VoiceConversionManaging` (lifecycle) vs `voiceConverting:
VoiceConverting = VoiceConversionClient()` (the actual convert/train calls) are ALSO
two separate objects.

**The one clean "terminal state first observed" hook already in the tree**: the
`ai.generationStatus` handler's doc comment (Commands.swift ~3320-3332) states
`audioPath` is populated "the FIRST time this observes state == 'succeeded'" (later
polls of the same job reuse the cached path). That first-observation edge is the
natural trigger point for roadmap scope ② ("unload-on-idle after a generation job
reaches a terminal state") — but note it fires on POLLING (an external agent calling
`ai.generationStatus`), not on an internal completion callback, so a design relying on
it needs the router/manager to observe that same transition itself, not assume an
agent will keep polling after success.

### RVC handlers — `Sources/DAWControl/Commands.swift`
- `case "vc.sidecarStatus":` line 4462. No params. Calls `await
  voiceConversionManager.status()` (4485). GET /health on 127.0.0.1:8002. Response:
  `VoiceConversionStatus` Codable — `{state, message, version?, engine?,
  baseModelPresent?, voiceCount?, pid?, phase?, startingForSeconds?}`. `phase` is
  ALWAYS nil for this sidecar (no phase classifier exists yet, unlike ACE's log-tail
  classifier) — explicit asymmetry vs ACE. `voiceCount` is 0 until training ships.
- `case "vc.sidecarStart":` line 4488. No params. Spawns `scripts/rvc/run.sh`. Same
  ~30s poll/timeout/"starting" discipline as `ai.sidecarStart`.
- `case "vc.sidecarStop":` line 4505. No params. SIGTERM→SIGKILL. Comment explicitly
  says: "the planning/identity/termination logic is now literally shared with
  [ai.sidecarStop], see Sources/AIServices/SidecarStopPlanner.swift" (m23-bb-1) — **this
  is the existing shared-primitive seam for m23-dl to build on.**

Handler backing type: `voiceConversionManager` — `Sources/AIServices/
VoiceConversionManager.swift`.

Right after the vc.sidecar* trio, `vc.convertVocals` (line ~4525) is a BLOCKING call
(no async job registry, unlike ai.generateSong) — its own long timeout
(`config.convertTimeoutSeconds`, default 300s), everything else on the fast default.

### MCP wrappers — `mcp-server/src/server.ts`
Lines 5956-6121, comment block starting ~5950 documents the whole sidecar-lifecycle
group. Key structural note: there are TWO ways tools get registered:
- `server.registerTool(...)` — the SDK's raw method, PERMISSIVE zod parsing (silently
  strips unknown keys before the handler/wire ever sees them). Used for pure reads
  with no params where an extra key can't misconfigure anything, per the doc comment
  at line 74-95.
- `registerTool(...)` (no `server.` prefix) — this file's OWN wrapper (defined line 96,
  doc comment 74-95) that forces `z.object(shape).strict()` for MUTATING tools, so an
  unknown key is a validation error AT THE MCP BOUNDARY. Also used by the 3 provider-
  calling generation tools (generate_lyrics/generate_song_suno/generate_image, m23-eh)
  that have NO backing wire command, making this wrapper their ONLY unknown-key guard.

Observed for the sidecar group specifically:
- `ai_sidecar_status` (5956) → `server.registerTool` (DIRECT/permissive — pure read).
- `ai_sidecar_start` (5981) → `registerTool` (WRAPPED/strict — mutating).
- `ai_sidecar_stop` (6003) → `registerTool` (WRAPPED/strict — mutating).
- `vc_sidecar_status` (6048) → `server.registerTool` (DIRECT).
- `vc_sidecar_start` (6075) → `registerTool` (WRAPPED).
- `vc_sidecar_stop` (6099) → `registerTool` (WRAPPED).

All six are thin passthroughs: `async () => toToolResult(() => bridge.send("ai.sidecarStatus"))`
etc. — no logic on the MCP side, `bridge.send` is the DawBridge WebSocket client to the
control port. Tool names are snake_case (`ai_sidecar_status`) mapping 1:1 to the dotted
wire command name (`ai.sidecarStatus`) — this is the naming convention m23-dl's new
tool(s) must follow.

## 2. Wire counts — DECOMPOSED (all three pins CONFIRMED, 2026-08-05)

### `allCommands` = 171 (Sources/DAWControl/Commands.swift), confirmed 3 independent ways
The array literal is `public static let allCommands: [String] = [` at **line 183**,
closing `]` at **line 402** (entries on lines 184-401).
1. Anchored-string count over the array body only (excludes `//` comment lines):
   `sed -n '184,401p' Commands.swift | grep -c '^\s*"[a-zA-Z]'` → **171**.
2. Unique `verb: "..."` literals from `rejectUnknownKeys` calls ACROSS THE WHOLE FILE:
   `grep -o 'verb: "[a-zA-Z.]*"' Commands.swift | sort -u | wc -l` → **171**, and a `diff`
   against the array's entry set is **byte-identical** (not just equal count — same
   171 names).
3. Actual call-site count `grep -c 'try params.rejectUnknownKeys(' Commands.swift` →
   **171**, matching 1:1.
   - The raw `grep -c 'rejectUnknownKeys'` (no anchor) returns **174** — decomposed as
     171 real call sites + 2 comment-only mentions of the word (lines 2303, 2320,
     prose like "rejectUnknownKeys from day one") + 1 the function's own definition
     (line 7523: `func rejectUnknownKeys(_ allowed: Set<String>, verb: String, ...)`).
     171 + 2 + 1 = 174. This explains where a naive count would drift.
   - Did NOT reproduce the specific "172 via a naive quoted-string count, comment
     inside the array" artifact from a prior pass verbatim, but the two candidate
     naive patterns I tried (`grep -c '"'` over the array body → 173, because of the
     two-line-spanning comment at 214-215 mentioning `"exactly one of...
     byTracks/toTrackId")`; and a comma-anchored quoted-string pattern → 171 clean)
     both illustrate the same lesson: a naive quote-counting grep is fragile near
     that comment block. The verb-set / call-site cross-checks are the reliable
     method and all three agree exactly at 171.
   - `rejectUnknownKeys([], verb: "vc.sidecarStop")` etc. confirm ACE/RVC sidecar
     verbs are present in both the array and the verb set, as expected.

### MCP tools = 174 (141 wrapper + 33 direct), confirmed exactly
`mcp-server/src/server.ts` — two registration paths (see §1 above):
- `grep -c '^registerTool(' server.ts` → **141** (wrapped/strict, mutating tools +
  the 3 no-backing-command generation tools).
- `grep -c '^server\.registerTool(' server.ts` → **33** (direct/permissive, pure
  reads — includes `ai_sidecar_status` and `vc_sidecar_status`, both no-param health
  reads).
- Sum: **174**. Exactly matches the pin.

### Copilot catalog = 74, confirmed, and the "AIServices returns 0" trap reproduced
- `grep -c 'CopilotTool(' Sources/DAWControl/CopilotCatalog.swift` → **74**. Matches
  the pin exactly.
- `grep -rc 'CopilotTool(' Sources/AIServices/` → every file **0** (grep -c exits 1
  on the whole invocation since there are zero total matches) — reproduces the
  documented trap: the catalog lives in `DAWControl`, not `AIServices`, and a
  same-shaped grep in the wrong directory confidently returns nothing.

**Bottom line: all three pinned wire counts (171 / 174 / 74) are independently
re-confirmed as of this recon pass, 2026-08-05, tree at `81a678c`. No drift.**

## 3. How a new command is added end-to-end

Traced `ai.installSpeechModel` / `ai.speechModelInstallStatus` (m23-n3b) — chosen over
a simpler additive command because it is the CLOSEST in-tree precedent to what m23-dl
will build: "start a locally-owned long job, return immediately, poll for status" is
exactly the shape a model-idle/lifecycle manager needs (per its own doc comment: "the
in-tree precedent for a locally-owned long job with PULL-based status is the stretch
render, not a blocking call"). Also directly useful: its actor is described as "held
ONE PER ROUTER, the `WhisperTranscriber` precedent" — i.e. CommandRouter already holds
one long-lived actor instance per app-level singleton concern, the same shape
`sidecarManager`/`voiceConversionManager` already have.

**Insertion points, in order, for a NEW additive command:**

1. **`Sources/DAWControl/Commands.swift` — `allCommands` array** (starts line 183, ends
   `]` at line 402). New entries go **appended at the very end**, each preceded by a
   comment naming the milestone id and invoking "the additive-at-end law" explicitly
   (verbatim pattern seen repeatedly: `// m23-XX: <one-line what/why>. APPENDED AT THE
   END (the additive-at-end law).`). This law is NOT just a style preference — a
   comment at line 356 says explicitly "so HEAD's list stays an exact PREFIX of this
   one" — i.e. never insert in the middle, never reorder, never rename a live entry.
2. **A `case "namespace.verb":` arm in `route(_:)`** (the big switch starting ~line
   466). Convention per arm, EVERY TIME: a doc comment block (params/response/behavior,
   often 15-40 lines, written for an AI reader — units, defaults, error shapes,
   idempotency), then `try params.rejectUnknownKeys([...allowed keys...], verb:
   "namespace.verb")` as the FIRST statement (even for zero-param commands: `[]`),
   then the actual handler logic, then `return .success(request.id, ...)` (or throw).
   For `ai.installSpeechModel` this is lines 4795-4857; for the poll half,
   4859-4865. New backing state (the coordinator/manager instance) is threaded through
   `CommandRouter`'s `public init(...)` (line ~404-448) as a DI-friendly parameter
   with a live default (e.g. `installCoordinator: WhisperModelInstallCoordinator =
   WhisperModelInstallCoordinator()`) — this is the injection seam tests use to fake
   it (see §5).
3. **`mcp-server/src/server.ts` — a `registerTool(...)` (mutating) or
   `server.registerTool(...)` (pure read) block**, snake_case name mapping 1:1 from the
   dotted wire name (`ai.installSpeechModel` → `ai_install_speech_model`), a
   `title`/richly-written `description` (units, defaults, "what NOT to assume", enum
   values spelled out) and a zod `inputSchema` mirroring the wire params. Body is a
   thin passthrough: `async (args) => toToolResult(() => bridge.send("ai.wireName",
   args))`. Placed in a clearly commented section matching the milestone id (`// -----
   Speech-to-text model install (m23-n3b) -----`).
4. **`Tests/DAWControlTests/<Feature>CommandTests.swift`** — control-layer test using
   the injected fake (§5).
5. **`Tests/AIServicesTests/<Feature>Tests.swift`** (or wherever the backing manager
   lives) — unit tests of the manager/coordinator itself, independent of the wire.
6. **`docs/ARCHITECTURE.md`** — the running command-namespace paragraph (~line 61) gets
   a new clause: `mXX-YY +N \`ns.verb1\`/\`ns.verb2\` — <one line>, mirrored as MCP
   tools \`ns_verb1\`/\`ns_verb2\` (OLD→NEW tools), no exception-table entry needed`
   (or, if the MCP name would NOT mechanically match the wire name, an explicit
   exception-table entry — not observed in this trace, but the paragraph's own
   phrasing implies one exists elsewhere). The wire-count headline (**"171
   commands"**) and the MCP-tool-count headline both get bumped in the SAME edit —
   ARCHITECTURE.md documents itself as having rotted THREE times from someone bumping
   one number and not the other ("totals rot invisibly" — see line 67's own
   post-mortem). **m23-dl must bump both numbers in the same commit that adds the
   command(s).**
7. **`CHANGELOG.md`** and **`docs/ROADMAP.md`** checkbox — ticked per repo convention
   (not directly observed in this trace but stated as house convention in CLAUDE.md:
   "Update docs/ROADMAP.md checkboxes when a milestone item lands").

**Bonus finding — the naive-172 artifact is already diagnosed, in ARCHITECTURE.md
itself** (line 67): *"Do NOT total `allCommands` by counting quoted strings in its
body: that returns 172, because the comment at lines 397-398 wraps a quoted phrase
across two lines."* This is the exact comment I independently located at (current)
lines 396-398: `// §1.2: neither wire schema surface can express "exactly one of` /
`// byTracks/toTrackId"). STRICTLY ADDITIVE...` — a naive `grep '"'`-per-line count
double-hits this two-line-spanning quoted phrase, landing on 172 instead of 171.
ARCHITECTURE.md ALSO already documents the reliable recipe (matches what I derived
independently in §2): `rejectUnknownKeys\(\s*\[[^\]]*\]\s*,\s*verb:\s*"([^"]+)"` →
171 distinct verbs, set-identical to `allCommands`.

## 4. Existing lifecycle primitives — ALL THREE 2026-08-05 CLAIMS RE-CONFIRMED, ZERO DRIFT

- **`unload` — exactly ONE real primitive in the tree.**
  `grep -rn "unload" Sources/ --include="*.swift"` → 4 hits total:
  - `Sources/AIServices/WhisperTranscriber.swift:200: public func unload() {` — the
    ONE real primitive (`{ loaded = nil }`, one line, doc: "Drop the loaded model.
    The next call reloads it (and pays the load cost again — the compile cache
    survives, the mapping does not).").
  - `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:974` — comment, "unloaded
    instance", unrelated.
  - `Sources/AIServices/ACEStepClient.swift:354` — comment, "unloaded/unmatched
    `model` name", unrelated.
  - `Sources/AIServices/Providers.swift:541` — comment, same phrase, unrelated.
  Confirmed exactly as recorded.
  - **NEW finding this pass (not previously recorded): `unload()` has ZERO callers.**
    `grep -rn "\.unload(" Sources/ Tests/ --include="*.swift"` and `grep -rn
    "unload()" Sources/ Tests/` both return ONLY the definition line — nothing in
    the app, control layer, or tests ever calls it. It is dead code today. There is
    also NO idle-timer/scheduling mechanism anywhere in `WhisperTranscriber.swift`
    (`grep -n "idle\|Idle\|timer\|Timer\|Task.sleep\|asyncAfter"` → zero hits) — no
    auto-unload-after-N-minutes exists for Whisper either. m23-dl is not "wiring up
    an existing idle path", it is building the idle-detection/scheduling mechanism
    from nothing, for at least one and possibly all three model consumers.

- **`mcp-server/src/` has ZERO occurrences of `unload`.** `grep -rn "unload"
  mcp-server/src/` → no output, exit code 1 (zero matches). Confirmed.

- **`modelLifecycle|residentModel|ModelManager` — zero across BOTH Swift and
  TypeScript**, re-verified with three separate greps, all exit 1 (zero matches):
  `Sources/` (all Swift), `mcp-server/src/` (TS), and `Tests/` (Swift, bonus check
  not in the original claim, added for completeness). No naming collision risk for
  a new `ModelManager`/`ModelLifecycle*` type name.

- **`Sources/AIServices/SidecarStopPlanner.swift`** (725 lines) — the shared stop
  mechanism m23-bb/m23-bb-1 built, referenced by BOTH `ai.sidecarStop`'s and
  `vc.sidecarStop`'s doc comments as "the planning/identity/termination logic is
  now literally shared." Read its header (lines 1-80): `enum SidecarStop` with a
  `SidecarStop.Identity` struct (pure predicate: `argsPattern`/`directoryPath`,
  "is this process ours") and documented invariants (never lie about state, a
  refusal mutates nothing, self/ancestor exclusion first, fail-open on pidfile /
  fail-closed on port, two pid-reuse re-confirmations, capture descendants before
  signalling, pid-exact only — never `pkill`/`pgrep`/`killall`).
  - **IMPORTANT for m23-dl's design: this file is STOP-IDENTITY logic only.**
    `grep -n "idle\|Idle\|timer\|Timer\|lastUsed\|lastActivity\|autoStop\|
    autoUnload" SidecarStopPlanner.swift` → zero hits. It answers "what should stop
    actually DO, and is it safe to signal this process" — it does NOT track usage
    recency, does NOT schedule anything, and has no idle-timeout concept at all.
    m23-dl gets a trustworthy, already-shared STOP mechanism for free (parameterized
    by `Identity` + `Vocabulary` per sidecar), but the "detect idle, decide when to
    call stop" half is genuinely new work, not a rename of something existing.

## 5. Test fake patterns — how the tree tests a sidecar without booting one

There are TWO layers, tested with TWO different techniques, and m23-dl should reuse
both:

### Layer 1 — control protocol (`Tests/DAWControlTests/SidecarCommandTests.swift`)
Tests `CommandRouter`'s routing/param-shape/response-encoding/error-surfacing ONLY —
never touches a process or the network. Pattern:
- `actor FakeSidecarManager: SidecarManaging` — a hand-written test double
  conforming to the SAME protocol (`SidecarManaging`) the real `SidecarManager`
  conforms to. Holds pre-set `statusToReturn` / `startResult: Result<SidecarStatus,
  Error>` / `stopResult: Result<..., Error>`, plus call counters
  (`statusCalls`/`startCalls`/`stopCalls`) so a test can assert exactly-once-called
  and (for the guard-ordering test) exactly-ZERO-calls when a param-validation
  error should short-circuit before the fake is ever touched.
- Injected via `CommandRouter`'s DI init:
  `CommandRouter(store: store, sidecarManager: sidecar)` — the SAME constructor
  parameter (`sidecarManager: SidecarManaging = SidecarManager()`) that production
  code leaves at its live default. **This is the exact seam m23-dl's new command(s)
  must go through** — no new test infra needed if the new lifecycle manager is
  injected the same way through `CommandRouter.init`.
- Tests cover: canonical-list membership, wire-shape threading (every field),
  omitted-optional-fields-stay-omitted, error-surfacing verbatim (including the
  m23-bb "stopFailed must never read as ok or as 'not running'" invariant), and the
  m23-n2h zero-param guard-ordering test (`rejectUnknownKeys` must run and reject
  BEFORE the fake manager's method is ever called — asserted via the call counter
  staying 0).
- The RVC equivalent (not fully re-read this pass, but same directory/pattern) is
  `Tests/DAWControlTests/VoiceConversionCommandTests.swift`.

### Layer 2 — the real manager, fake network only (`Tests/AIServicesTests/SidecarManagerTests.swift`)
Tests the REAL `SidecarManager` (real path resolution, real HTTP client, real
process-signal logic) against a FAKE loopback HTTP server and, separately, a
`dryRun` config flag that suppresses process spawn/signal:

- **`StubHealthServer`** (defined at the top of the test file, `import Network`) —
  a minimal in-process TCP responder built on Apple's `Network` framework:
  `NWListener` bound to `127.0.0.1:0` (port `.any`, i.e. an EPHEMERAL port so
  parallel test runs never collide), whose connection handler ignores whatever the
  client sent and writes back ONE canned HTTP response
  (`StubHealthServer.healthyResponse(version:ditModel:lmModel:)` builds a real
  `HTTP/1.1 200 OK` wrapping ACE-Step's actual `/health` JSON envelope shape
  `{"data": {...}, "code":200, "error":null}` — cross-checked against
  `acestep/api/http/model_service_routes.py` per the doc comment).
  `StubHealthServer.malformedResponse()` gives valid-JSON-but-wrong-shape for a
  separate error branch. `StubHealthServer.unusedLoopbackPort()` allocates then
  immediately frees a port, so a probe against it deterministically sees
  "connection refused" (exercises notInstalled/installedNotRunning branches).
  The real `SidecarManager` is then constructed with `configuration:
  .init(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, acestepDir: dir)`
  — i.e. `baseURL` is the ONLY thing redirected; everything else (health-probe
  parsing, state classification, pidfile handling) runs for real against the fake
  port.
- **`dryRun: Bool`** (`SidecarManager.Configuration.dryRun`, default `false`) — a
  SEPARATE seam, orthogonal to the fake server: when `true`, `start()`/`stop()`
  resolve real paths/plans and report what they WOULD do (message prefixed
  `[dry-run]`) WITHOUT spawning or signaling any real process. Used in tests that
  need to prove "stop() never signals when X" (e.g.
  `dryRunStaysHonestAndInert`: pidfile names a stranger pid, health probe (via
  `StubHealthServer`, real network) reports healthy, `dryRun: true` — asserts the
  message says `[dry-run]` and NEVER "not running" and the real (non-fake, actually
  spawned-by-the-test) stranger process is still alive afterward
  (`kill(strangerPid, 0) == 0`)). Both seams (fake server + dryRun) are combined
  freely in the same test.
- Process-signal tests (`SidecarManagerStopDescendantTests`, ~line 1000+) spawn a
  REAL harmless child process from the test itself (to reproduce the
  parent-spawns-python-child topology) rather than faking process trees — this is
  the ONE place actual OS processes get created, and they are the test's own
  disposable children, never the real ACE-Step/RVC binaries.

### For m23-dl specifically
A model-lifecycle manager (idle detection → auto-`stop()`) can be verified
end-to-end WITHOUT ever loading the 54 GB model by: (a) unit-testing the
idle-detection/scheduling logic in isolation with an injected clock seam — **CORRECTED
from an earlier pass of this recon: such a seam DOES exist as a precedent, see below**
— (b) reusing `StubHealthServer` + `dryRun` to prove the manager calls `stop()` at the
right moment without a real process being signalled, and (c) a `FakeSidecarManager`-
style double at the control-protocol layer if the lifecycle manager itself becomes
injectable into `CommandRouter` (e.g. for a new `ai.sidecarIdleStatus`-shaped
command). None of layers (a)/(b)/(c) requires port 8001/8002 or a real model load.

**Correction — a clock-injection precedent DOES exist, and one is a near-exact
shape match.** A tree-wide grep (`ContinuousClock|SuspendingClock|nowProvider|
dateProvider|now: @Sendable () -> Date`) turns up TWO real seams, one of which is the
closest thing to a design precedent for m23-dl found in this whole recon:
- **`Sources/DAWAppKit/GenerationPresenceModel.swift:164`** —
  `private let now: @Sendable () -> Date`, injected via `init(... now: @escaping
  @Sendable () -> Date = { Date() })` (line 173), with the doc comment "Injected
  clock so linger/elapsed logic is deterministic in tests." **This model ALREADY
  composes exactly the two things a lifecycle manager needs**: it takes a
  `sidecarStatus: @Sendable () async -> SidecarStatus` closure (line 158, i.e. it
  already polls `SidecarManager.status()`-shaped state) AND an injected clock, and
  uses them together to drive linger/expiry timers (`succeededLingerSeconds: 6`,
  `sidecarReadyLingerSeconds: 20`, both `TimeInterval` constants). It lives in
  `DAWAppKit` (UI-facing presence-card polling, not itself a lifecycle-STOP
  mechanism), so it is not directly reusable as-is, but its clock-injection PATTERN
  (`@Sendable () -> Date`, defaulting to real `Date()`, swapped for a fixed/stepped
  closure in tests) is exactly the technique m23-dl's own idle-timer needs, with an
  in-tree test-determinism precedent to copy.
- **`Sources/DAWCore/UndoJournal.swift:96`** — `var now: () -> ContinuousClock.Instant
  = { ContinuousClock.now }`, same pattern, `ContinuousClock` flavor instead of
  `Date`.
- Widespread but LESS relevant: `ContinuousClock.now`/`.Instant` used directly
  (not behind an injectable closure) throughout `DAWEngine` (`InstrumentSourceNode`,
  `PolySynthInstrument`, every `Effects/*.swift`, `MIDIInputManager`,
  `AutomationRenderer`) for real-time voice-retirement bookkeeping — real-time-safe
  code that reads the wall clock directly is correct there (no test-determinism need
  at audio-thread granularity) and is NOT a pattern to copy for a UI/control-layer
  idle timer.
- **Conclusion, revised: do not claim "no clock seam exists in the tree" — that was
  wrong. The precedent is `@Sendable () -> Date` / `() -> ContinuousClock.Instant`,
  defaulted to the real clock, swapped in tests; `GenerationPresenceModel` is the
  house style's best worked example of using one for exactly an idle/linger/expiry
  purpose against sidecar-shaped status.**

### Two more insertion points a NEW command must not miss (added after advisor review)

- **`claude-plugin/server/index.mjs`** — a SEPARATE, already-built mirror of
  `mcp-server/src/server.ts`'s tool set (also 174 tools total, confirmed by the same
  decomposed count: `grep -c '^server\.registerTool('` → 36, `grep -c
  '^registerTool('` → 138, sum 174 — note this is a DIFFERENT 36/138 split than
  server.ts's 33/141, even though the total matches; the two files are not
  structurally identical line-for-line). **This file is confirmed STALE right now**:
  its `ai_sidecar_stop` description (line ~46125) still reads the PRE-m23-bb wording
  ("graceful SIGTERM via its pidfile... Succeeds as a no-op... if it wasn't
  running" — no mention of the port-holder fallback, the `stopFailed` error class, or
  the "never says not-running while still up" invariant that server.ts's version
  documents in full, confirmed by direct comparison of the two description strings).
  This is a live, PRE-EXISTING rot (not something m23-dl caused) — the roadmap's own
  m23-bb-1 close note already flags it and says "tool count unchanged at 174, so no
  re-pin" was the prior judgment call. **Any m23-dl tool must be added HERE TOO or it
  silently misses this mirror**, and the implementer should decide whether to also
  fix the pre-existing `ai_sidecar_stop` staleness while touching this file (separate
  from m23-dl's own scope, but adjacent and cheap to fix in the same edit).

- **`Sources/DAWControl/CopilotCatalog.swift`** — the curated 74-of-171 subset the
  in-app copilot (not an external MCP agent) can call. Checked membership for the
  sidecar/generation group: `ai.sidecarStart` IS in the catalog (line 861,
  `schemaObject([])`), but **`ai.sidecarStatus` and `ai.sidecarStop` are NOT** —
  confirmed by grep, only one of the three sidecar-lifecycle verbs is exposed to the
  in-app copilot. `ai.generateSong`/`ai.generationStatus`/`ai.fixClipRegion` are
  present (lines 865-933+). This is a real, existing precedent worth carrying into
  m23-dl's design: **the in-app copilot today can START the sidecar but cannot STOP
  it or read its raw status** — whatever new "which model is resident"
  (scope ④) or unload-related surface m23-dl adds, catalog membership is a
  DELIBERATE per-command decision already made asymmetrically once, not a
  mechanical mirror of the wire command list, and needs its own explicit call
  (plausibly: expose a read-only residency status to the copilot, withhold an
  explicit "unload now" verb the way stop is withheld today — but that is a product
  decision, not this recon's to make).

## 6. Whisper and RVC as additional model consumers

### WhisperTranscriber (`Sources/AIServices/WhisperTranscriber.swift`)
- Has `public func unload()` (line 200) — one line, `{ loaded = nil }` — dropping the
  loaded WhisperKit model so the next `transcribe()`/`prewarm()` call reloads it (pays
  load cost again; "the compile cache survives, the mapping does not").
- **Nothing calls it** (§4 — zero call sites anywhere in `Sources/`/`Tests/`) and
  **there is no idle path at all** — no timer, no scheduling, no "N minutes since last
  use" tracking anywhere in the file. `loadedModelVariantDirectoryName` (line 186) is
  the only introspection surface (a computed property reading `loaded?.descriptor...`,
  no timestamp).
- Not process-based like ACE/RVC — it's in-process CoreML weights held in a class
  property (`loaded`), not a subprocess with a pidfile/port. A lifecycle manager for
  Whisper would look structurally different from the ACE/RVC one: no `SidecarStop`
  identity/signal logic applies; it would just need to call `unload()` on a timer/
  after N idle minutes, and the memory being freed is the app's own process memory,
  not a child process's.
- Wire surface: `clip.transcribe` (blocking call) and `ai.installSpeechModel`/
  `ai.speechModelInstallStatus` (start+poll, via `WhisperModelInstallCoordinator`, see
  §3). No existing `ai.speechModelUnload`-shaped command; would be new if wired.

### VoiceConversionManager / RVC (`Sources/AIServices/VoiceConversionManager.swift`, port 8002)
- **Confirmed structurally symmetric with `SidecarManager` (ACE), by design**:
  - Protocol twins: `VoiceConversionManaging` (`Sources/AIServices/
    VoiceConversionStatus.swift:96`) is method-for-method identical in shape to
    `SidecarManaging` (`Sources/AIServices/SidecarStatus.swift:113`) — both declare
    exactly `status() async -> Status`, `@discardableResult start() async throws ->
    Status`, `@discardableResult stop() async throws -> Status`. The doc comment on
    the RVC one says outright: *"the `SidecarManaging` twin for the RVC voice-
    conversion sidecar."* **These two protocols could be unified into one generic
    `SidecarManaging<Status>`-style protocol today with no behavior change** — a
    natural anchor point for a shared lifecycle-manager abstraction.
  - `VoiceConversionManager.Configuration` (line 471) has its OWN `dryRun: Bool`
    (line 481, default false) — same test seam as ACE's.
  - Stop logic is LITERALLY SHARED via `SidecarStop` (`Sources/AIServices/
    SidecarStopPlanner.swift`, confirmed §4): `VoiceConversionManager` has its own
    `stopIdentity: SidecarStop.Identity` (line 273) and `static let stopVocabulary =
    SidecarStop.Vocabulary.rvc` (line 278), and its `stop()` calls
    `SidecarStop.terminateTree`/`resolvePlan`/`gatherFacts`/`dryRunReport` etc. — the
    exact same enum `SidecarManager` uses, parameterized differently. This IS the
    "shared protocol" m23-dl can extend for a lifecycle manager: whatever new
    idle-tracking/auto-stop logic gets built, it can plausibly live as a THIRD
    parameterization of the same shared-primitives pattern (`Identity` +
    `Vocabulary`-style config) rather than two separate copies.
  - Wire symmetry: `vc.sidecarStatus`/`Start`/`Stop` mirror `ai.sidecarStatus`/
    `Start`/`Stop` exactly (confirmed §1) — same states, same no-op-on-already-
    stopped behavior, same stopFailed error class, one deliberate asymmetry
    (`phase` always nil for RVC — no log-tail classifier built for it yet, unlike
    ACE's `SidecarStartPhase`).
- **No idle-timeout/lifecycle-manager code exists for RVC either** (§4's
  `SidecarStopPlanner.swift` idle-keyword grep was zero; a same-shaped grep across
  `VoiceConversionManager.swift` for `idle|Idle|timer|Timer|lastUsed|lastActivity`
  turns up nothing beyond the already-confirmed absence in the shared planner).

## 6b. TREE STATE WARNING — the working tree is NOT at the clean `81a678c` pin

Discovered incidentally via `git status` while confirming no stray/duplicate
lifecycle code exists (§4's broader-net grep). **The tree right now carries
substantial UNCOMMITTED changes across exactly the files m23-dl will need to
touch:**

```
 M Sources/AIServices/SidecarManager.swift         | 139 +++++++--
 M Sources/AIServices/SidecarStatus.swift          |  10 +-
 M Sources/AIServices/TranscriptionBeats.swift     | 140 ++++++++-
 M Sources/AIServices/VoiceConversionManager.swift | 151 +++++++--
 M Sources/AIServices/WhisperModelCatalog.swift    | 388 +++++++++++++++++++++++-
 M Sources/AIServices/WhisperTranscriber.swift     |  53 +++-
 M Sources/DAWControl/Commands.swift               | 102 ++++++-
 M mcp-server/src/server.ts                        | 119 ++++++--
 8 files changed, 991 insertions(+), 111 deletions(-)
?? Sources/AIServices/SidecarProcessDiscovery.swift   (untracked, never committed)
?? Sources/AIServices/SidecarStopPlanner.swift        (untracked, never committed)
```

This is consistent with — and I believe explained by — the SAME-DAY (2026-08-05)
roadmap close-outs I read directly in §7 below: `docs/ROADMAP.md`'s own m23-bb
close-out text says verbatim *"discovery split into a new ONE home
`Sources/AIServices/SidecarProcessDiscovery.swift`"*, matching one of the two
untracked files exactly, and this recon's own reading of `SidecarStopPlanner.swift`
(§4) matches the roadmap's description of that same close-out. **All of the wire
counts I verified in §2 (171/174/74) were measured against THIS uncommitted tree
state**, not against the `81a678c` commit — so they are the numbers that matter for
someone starting work now, but they are NOT what `git show 81a678c:...` would give.

I have NOT audited whether this pending diff is fully tested/intentional (that is
beyond a read-only wire-recon pass, and the standing rule is commits happen only on
the user's word — an uncommitted-but-legitimate diff is the EXPECTED shape of a
day's autonomous work, not evidence of a problem). **Flagging for whoever implements
m23-dl next: confirm this diff's provenance (which roadmap item(s) it belongs to,
whether the suite is green against it) before adding more changes on top of it** —
building new sidecar-lifecycle code on an unverified base compounds risk if any part
of this pending diff turns out to be the kind of unauthorized/unreported work the
project has hit before (m23-bs-3a, per the standing memory note). This is an
observation, not a finding of wrongdoing — the far more likely explanation is simply
"today's closed items (m23-bb, m23-bb-1, and others touching Whisper/TranscriptionBeats)
are sitting uncommitted pending the user's commit word," which matches the project's
own stated commit discipline exactly.

## 7. The roadmap item's own scope text (docs/ROADMAP.md, m23-dl entry, ~line 861)

Read directly rather than relying on memory. Key points, verbatim/paraphrased:

- User's own words (2026-08-04): *"We should also manage model loading and should
  unload ACE once we are done with song generation or when we attempt to load other
  model."*
- Framed as promoting an EXISTING MANUAL discipline (the standing "kill ACE pid-exact
  after every test" rule, since ACE holds ~75 GB while RSS reports ~1 GB) into a
  PRODUCT FEATURE.
- **Blocker (m23-bb) is CLEARED** — re-verified in this recon pass too (§4/§1): the
  stop verb genuinely stops things now, `SidecarStopPlanner.swift` is in the tree.
  Item is machine-workable.
- **Scope, smallest useful first (the roadmap's own ordering):**
  ① fix `ai.sidecarStop` so it actually stops — DONE (m23-bb).
  ② unload-on-idle after a generation job reaches a terminal state.
  ③ unload-before-load — mutual exclusion between large models (this is the leg that
     m23-dg, the Music Flamingo evaluation item, is BLOCKED on — "two large models on
     one machine is precisely the condition that makes an unload manager mandatory").
  ④ surface which model is resident, so the answer is observable rather than inferred.
- **"Design it for N models, not two"** — ACE (8001) + RVC (8002) already coexist, a
  third (Music Flamingo, m23-dg) is a live near-term candidate. Explicitly warns
  against a pairwise special case.
- **Verification must be RESIDENT MEMORY, not the process table or RSS** — the
  roadmap calls out the defining trap of this whole area: RSS reports ~1 GB for a
  75 GB hold, and `kill -0` succeeds on a zombie. "Unloaded" means the memory came
  back AND the port is free — assert BOTH, with a POSITIVE CONTROL proving the check
  can fail (i.e. the test must demonstrate it would catch a still-resident model, not
  just that it passes on an already-stopped one).
- **"Follow the nonce lesson from m23-ah"** — cited pattern: return a monotonic
  counter/generation-id in the status response so "did this actually unload?" is
  something a caller OBSERVES from the response shape rather than something it must
  INFER from timing. (Not independently re-verified in this pass — flagged as an
  implementation-design pointer, not a wire fact.)
- Weight M. Route: `mcp-integration-engineer` (sidecar control) with `daw-architect`
  on the exclusion policy (③, mutual exclusion between models, is a cross-module
  design decision, not pure wire plumbing).
- Downstream dependent: **m23-dg (Music Flamingo evaluation) lists m23-dl as a HARD
  PREREQUISITE** for the reason above (two large local models at once).

### Open design fork, deliberately NOT resolved by this recon (route: daw-architect, per the roadmap's own routing)

Two legitimate in-tree precedents point OPPOSITE directions on whether m23-dl needs
new wire commands at all, and the recon should hand both to the design step rather
than pick:

- **Precedent for "additive field on an existing payload, zero new commands, wire
  counts stay 171/174/74"**: m23-bb (the stop-fix prerequisite) shipped with
  "Commands.swift is COMMENT-ONLY, 0 new cases — verified, so wire counts stay
  171/174/74." Scope ④ ("surface which model is resident") could plausibly ride on
  the EXISTING `ai.sidecarStatus`/`vc.sidecarStatus` response shape (add a residency/
  last-used/monotonic-unload-counter field) rather than a new command.
- **Counter-precedent, a caution against reflexively growing a payload**: m23-ef's
  own close-out (quoted in ARCHITECTURE.md line 67's history) explicitly reasoned
  "an additive wire change nobody asked for is still a wire change" when deciding
  NOT to add fields that were merely convenient — i.e. this codebase treats payload
  growth as a real cost, not a free alternative to a new verb, and has walked one
  back before.
- Scope ② (unload-on-idle) and ③ (mutual exclusion before loading another model) are
  BEHAVIORAL changes inside the manager(s), not obviously representable as a status
  field at all — they may need at minimum a policy/threshold SETTER (a genuinely new
  verb, e.g. something idle-timeout-configuration-shaped) even if the STATUS read
  rides on an existing payload.
- This fork — new command(s) vs. additive field(s) on existing ones vs. some mix —
  changes §3's step list materially (whether §2's 171/174/74 pins move at all) and
  is exactly the kind of cross-module design call the roadmap item's own routing
  note assigns to `daw-architect`, not something this recon should preempt.

### Bottom line for design
Three model consumers, two clearly shaped alike (ACE `SidecarManager` / RVC
`VoiceConversionManager` — process-based, port-probed, `SidecarStop`-backed, already
protocol-twinned) and one shaped differently (Whisper `WhisperTranscriber` — in-process
CoreML weights, no subprocess, has a dead `unload()` primitive but no scheduling). A
model-lifecycle manager could plausibly ship as ONE generic idle-tracker parameterized
over "how do I check activity" + "how do I release" (calling either `SidecarManaging.
stop()` for ACE/RVC or `WhisperTranscriber.unload()` for Whisper), but the RECON does
not find any existing scaffolding for the idle-detection half — that is new work in
every case, not a wire-up of something dormant.
