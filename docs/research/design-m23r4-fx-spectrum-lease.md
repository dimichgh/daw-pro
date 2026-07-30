# m23-r4 — `fx.spectrum`: ownership, TTL lease, and PRE/POST-fader labelling

**Design, 2026-07-28 · daw-architect · for implementing agents (route: mcp-integration-engineer, with one DAWCore/DAWApp step for `swift-app-engineer`).**
Scope: roadmap line 457. Supersedes nothing; extends `docs/research/design-m23r-per-insert-spectrum-tap.md` (r1–r3 shipped the engine + UI halves).

---

## 0. Decisions, in one screen

| # | Decision |
|---|---|
| D1 | **Ownership = a named-owner `Set` in `ProjectStore`** (`.ui`, `.control`). Not a numeric refcount, not wire-side refusal, not fan-out. The engine's arm and its N = 8 cap are **untouched**. |
| D2 | **The 3 s TTL lease lives in `DAWControl` and only there**, swept lazily **at the top of `fx.spectrum` only** (not in `handle`). Expiry releases the `.control` owner; the engine key stays armed while `.ui` holds it, and vice versa. |
| D3 | **No fan-out / coalescing layer is built** — the analyzer already is one. See §1; this is a finding that *shrinks* the item. |
| D4 | The response carries **`tapPoint`** (`postInsertPreFader` \| `postInsertPostFader`) computed in **one DAWCore home**; **no pinned UI string changes**. |
| D5 | **`trackId` is REQUIRED** and takes the `"master"` sentinel via `parseFXTarget()` — a deliberate deviation from the roadmap's `{trackId?}`. |
| D6 | The response encodes `MasterAnalysisSnapshot` **verbatim through the same `JSONValue(encoding:)` path as `mixer.masterAnalysis`** (so it is `levelDB`/`peakDB`, not the roadmap's shorthand `levelDb`), plus `armed`, `tapPoint`, `leaseSeconds`. |
| D7 | `ProjectStore.setInsertAnalysisArmed` returns an **outcome enum**, not `Bool`, so the cap refusal can name the cap. |

Wire count **161 → 162**. MCP tools **164 → 165**. Copilot catalog **67 → 68**.

---

## 1. Finding: the briefed "shared drain" failure mode is not real

The brief (and `ProjectStore.swift:1204-1206`, and `EngineProtocol.swift:618-624`) state that `insertAnalysis()` admits **exactly one consumer**, because two callers "split the sample stream and BOTH run slow with no error surfaced anywhere." That inference does not survive reading the analyzer:

- `Sources/DAWEngine/Analysis/InsertSpectrumTap.swift:252-295` — `drainAndSnapshot()` copies **all** available frames (capped at `maxDrainFrames = 4096`, `:88`) and calls `analyzer.processMix(...)` once, then returns `analyzer.snapshot()`.
- `Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift:297-317` — `process(_:)` keeps an **internal FIFO** (`fifoFill`) and its own doc says "Feed mono samples (any count). Runs zero or more analysis frames as the internal FIFO fills." It is **chunk-size invariant**.
- `:368-387` — `accumulateStereo` is hop-aligned with the same property.
- `:461-505` — `snapshot()` is **pure**: it reads smoothed state and mutates nothing.
- `:604-608` — peak release is applied **per analyzed frame**, not per `snapshot()` call.

Therefore two consumers draining the same tap **lose no frames and read the same published snapshot**. Splitting the drain between two calls changes only *which call* crosses the FFT hop boundary; the analyzer accumulates across calls and both callers then read the same fresher value. Failure mode 1, as briefed, does not exist. **Do not build coalescing, broadcasting, or a snapshot memo.**

**The corrected invariant — put this text in the doc comments (it is the RT-safety line of the whole design):**

> N consumers are safe **provided they are all on the main actor** — the SPSC ring's single-consumer contract is about *threads*, and `ProjectStore` being `@MainActor` is what enforces it. What is not safe is an **unowned disarm**.

**Honest residue (do not lose this).** Ballistics advance in *analyzed-frame* time, not wall-clock, and `maxDrainFrames = 4096` (85 ms @ 48 kHz) drops oldest (`:257-262`). So:

- A poller slower than ~12 Hz discards most frames; `peakDB` release and flux smoothing then run slower than wall-clock. **State the ~12 Hz floor in the MCP tool description.**
- A fast co-consumer (the UI at 60 Hz) *changes what the wire reads* by keeping the analyzer fed. **Consequence for the gate: never pin exact dB values across "UI also polling" vs "wire alone." Pin the tone's band INDEX, which survives both.**

Failure mode 2 — the **disarm stomp** — is real, symmetric, and silent in both directions, and it is the whole reason this item needs a design:

- `Sources/DAWApp/DAWProApp.swift:1300-1310` — `releaseInsertSpectrum` disarms **unconditionally**; closing an EQ card would kill a wire lease.
- A 3 s TTL expiry would disarm **unconditionally**; it would kill the user's live EQ spectrum with no indication (`AudioEngine.swift:1512-1517`, "Disarming always reports true").

---

## 2. D1 — ownership: a named-owner `Set` in `ProjectStore`

**Decision.** `ProjectStore` keeps `[InsertAnalysisTarget: Set<InsertAnalysisOwner>]`. Arming inserts the owner and (if the set was empty) arms the engine. Disarming removes **that owner only** and disarms the engine **only when the set becomes empty**. The engine's `Set<InsertAnalysisKey>` and its `maxArmedInsertAnalysis = 8` are not touched.

**Why a `Set` of named owners and not a numeric refcount.** A count underflows or leaks on unbalanced calls, and both parties here are naturally unbalanced: the UI re-arms idempotently on every card retarget, and the wire re-arms on every poll. A named-owner set is **idempotent in both directions** — exactly the property the engine's own arm has (`AudioEngine.swift:1518-1522`, "Idempotent: the tap survives a re-arm"). The store's shape mirrors the engine's shape, which is the house's ONE-home reflex.

**The owner set must never gate ARMING — only DISARMING.** The cap stays solely in the engine. If the store ever refused an arm based on its own bookkeeping, a stale owner entry (effect deleted, engine already pruned it at `AudioEngine.swift:1526-1533`) would let the wire refuse a 9th arm the engine would have accepted — a second home for the cap. The store's set is a *release* interlock, nothing else.

### Alternatives, and why they lose

**(a) The wire REFUSES to arm an insert the UI currently holds.** Loses on two independent counts.
1. *Product.* The flagship AI-native scenario is "agent, make this vocal less boxy" **while the user watches the EQ card**. Refusing precisely when the card is open kills the scenario, and the refusal depends on invisible UI state (which card is open), so the agent cannot predict or explain it.
2. *Layering.* `DAWControl` cannot see `AppModel`. Enforcing this rule requires the store to publish who holds what — i.e. it needs D1's machinery anyway, in order to implement a worse policy. And it is **only half a fix**: it does nothing about the UI's unconditional release stomping a wire lease (`DAWProApp.swift:1300-1310`).

**(b′) A numeric refcount.** Same placement as D1 but underflows/leaks under the idempotent call patterns both parties actually use. Strictly dominated by the owner set.

**(c) Fan-out / broadcast so one drain feeds N consumers.** Loses because **it is already true** (§1) — it would be new machinery to re-implement a property `MasterMixAnalyzer` already has, and it would introduce a coalescing window that is either too short (still double-drains) or too long (stale UI). It also fixes the *wrong* failure: it does nothing about the disarm stomp.

### Failure modes of D1, and their mitigations

| Failure | Mitigation |
|---|---|
| A stale `.ui` owner (window torn down without release) pins a tap forever. | The UI's `armInsertSpectrum`/`releaseInsertSpectrum` token dance already exists (`DAWProApp.swift:1283-1310`) and is unchanged; the store's set is keyed by owner, so a *repeat* UI arm cannot accumulate. The N = 8 cap is the backstop. |
| Store set and engine set diverge after an effect is deleted. | The engine prunes dead keys before testing the cap (`AudioEngine.swift:1524-1533`). The store's set is advisory for *release only*, so a stale entry costs at most one deferred disarm, never a wrong reading. Optional hardening: drop store entries in the same place the store already reacts to effect removal. |
| Someone adds a third owner and forgets a release path. | `InsertAnalysisOwner` is a closed enum in DAWCore; adding a case is a compiler-visible event. |

---

## 3. D2 — where the lease lives, and how expiry interacts with a UI arm

**Placement.** `Sources/DAWControl/InsertSpectrumLeases.swift` — a small `@MainActor` type held by `CommandRouter` as `private let`/`private var`, in the same slot pattern as `transcriber` / `installCoordinator` (`Commands.swift:100-125`). One per router, so "arm, then poll" sees the same state. **The lease never appears in DAWCore, DAWEngine, or the UI.**

**Clock.** The lease takes an **injectable monotonic now-provider** (`ContinuousClock.Instant` / `DispatchTime.uptimeNanoseconds` in production). *Never `Date()`* — it is non-monotonic across NTP steps, and a `Date()`-based lease forces a real 3-second sleep into the gate. Tests drive the provider directly.

**TTL.** `public static let defaultTTL: Duration = .seconds(3)`. Pin it **against a literal, in its own leg** (§8 L6). Without that pin, a 3 s → 300 s mutation passes every behavioural leg, because those legs use the injected clock.

**Sweep trigger: at the top of `fx.spectrum`, and nowhere else.** Rejected: sweeping in `CommandRouter.handle`. The *purpose* of the sweep is to keep the cap refusal honest, and the 9th arm **is itself an `fx.spectrum` call**, so an `fx.spectrum`-local sweep always runs exactly when it matters. Sweeping in `handle` buys only "reaps sooner during unrelated work," at the cost of a diff through the path all 162 commands flow — a bad trade on a strictly-additive item.

**Residual, stated plainly (put it in the command's doc comment):** a lease can outlive its TTL while no `fx.spectrum` arrives. It is bounded by N = 8, it costs two `memcpy`s per render block per leaked tap plus ~230 KB, and the next `fx.spectrum` of any kind reaps it.

**A key both parties want.** Both hold slots; the engine key stays armed while either holds it.

- Lease expiry → removes `.control` only → the UI's card keeps measuring, uninterrupted.
- Card close / retarget → removes `.ui` only → the agent's lease keeps measuring.
- Neither party can observe the other's presence, and neither needs to.
- `armed` in the response means **"the control-plane lease is held as of this response"** — *not* "the engine tap is armed" (which may be true because the UI holds it). This is the only honest meaning for an agent: it answers "will my next poll still work without re-arming?"

**The N = 8 cap is first-come-first-served across `.ui` and `.control`. Verdict: ACCEPT and document; do not reserve a slot.** An agent holding 8 leases makes the user's next EQ card open fall to the honest-floor state — `armInsertSpectrum` is refused, `effectEditorSpectrumIsMeasuring` reads false, and the card shows "The spectrum is not running for this insert right now — the flat green floor is honest, not a silent track" (`EQCurveEditorModel.swift:715`). That is honest rather than a lie, and the 3 s TTL bounds it to a few seconds after the agent stops polling. The alternative — reserving one slot for `.ui` — puts a **cap policy in the store**, which is exactly what D1 refuses. Known rough edge, filed here rather than discovered in beta: the help string does not hint that taps are *exhausted*, only that this one is not running. If that reads badly in use, the fix is a help-string variant driven by the refusal reason, not a reservation.

---

## 4. D3 — PRE/POST-fader labelling

### The measured facts (already pinned; do not re-measure)

- `Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift:295-341` — a **strip** insert tap is **PRE-fader**: 1 kHz band moves **< 0.5 dB** when the track fader goes 1.0 → 0.5.
- `:373-418` — a **master** insert tap is **POST-fader**: the same move shifts the band by **≈ 6.0206 dB**.

**The mechanism, so nobody calls it a bug.** The tap is always POST-insert. What differs is where the fader sits relative to the chain: the strip sandwich is `sumMixer → chainHost → mixer` (fader downstream of the walk), while the master path is `mainMixerNode → masterChainHost → outputNode` (`PlaybackGraph.swift:308`) with the master fader implemented as `mainMixerNode.outputVolume` (`:1793`, `:1812`) — i.e. **upstream** of the master walk.

### Decision

1. **One home for the label.** New file `Sources/DAWCore/InsertSpectrumTapPoint.swift`, built on the `ArrangeDropSnap` model — a `struct` with a **`fileprivate init`** and static constants, so no other file can mint one and divergence is unrepresentable:

   - `public static let postInsertPreFader` / `postInsertPostFader`
   - `public var wireValue: String` (`"postInsertPreFader"` / `"postInsertPostFader"`)
   - `public var explanation: String` — one sentence each, the text the MCP description and any future UI label both quote.
   - `public static func forInsert(trackID: UUID?) -> InsertSpectrumTapPoint` — **the only way to obtain one**: `trackID == nil ? .postInsertPostFader : .postInsertPreFader`.

   Do **not** make this an enum: public enum cases are constructible anywhere, which is exactly the divergence the `fileprivate init` prevents.

2. **The wire always carries `tapPoint`**, on every `fx.spectrum` response including `arm:false`. An agent comparing a strip curve with `mixer.masterAnalysis` reads one field and knows whether the fader is in the picture.

3. **No `curveHelp` string changes.** The narrowing that makes this safe: **the UI never draws a master *insert* tap.** `DAWProApp.swift:1330-1333` sends a master target to `store.masterAnalysis()` and only a track target to `store.insertAnalysis(...)`. The track help string at `Sources/DAWAppKit/EQCurveEditorModel.swift:715` already says "measured BEFORE the fader," and the master string at `:711` is explicitly byte-pinned. **Touch neither.** Instead, add an agreement pin (§8 L9) asserting the existing track string and `InsertSpectrumTapPoint.forInsert(trackID:)` say the same thing — so a future edit cannot drift them apart.

4. **Fix the two doc comments that are now wrong**, since implementers read them as spec:
   - `Sources/DAWCore/EngineProtocol.swift:618` says "Measured pre-fader and pre-PDC" **unconditionally** — false for `trackID == nil`. Rewrite to state both cases and point at the two pinned legs.
   - `Sources/DAWCore/ProjectStore.swift:1204-1206` and `EngineProtocol.swift:622-624` — replace the "exactly ONE consumer" warning with the §1 invariant **verbatim**. Do not delete it to nothing; the main-actor clause is what makes N consumers safe.

5. **Do NOT claim mute/pan behaviour in the MCP description** unless it is measured. Mute and pan are strip-mixer parameters and are *expected* to behave like the fader, but only the fader was measured. If the description is to say "a muted track still shows a full-strength strip spectrum" — which is genuinely useful and genuinely surprising — add the leg (§8 L10, clone of `:295-341` with `isMuted: true`). Otherwise say nothing about mute.

---

## 5. Wire contract — `fx.spectrum`

**Params** (`rejectUnknownKeys(["trackId", "effectId", "arm"], verb: "fx.spectrum")`):

| key | required | meaning |
|---|---|---|
| `trackId` | **yes** | Track/bus UUID **or the exact string `"master"`** — parsed by the existing `params.parseFXTarget()`, the ONE home for the sentinel (`Commands.swift:1262-1268`). |
| `effectId` | **yes** | Effect UUID — `params.requireEffectID()`. |
| `arm` | no, default `true` | **Two states only.** `true` = arm-or-refresh the lease, then read. `false` = read-then-release. **There is no peek mode**; say so in the doc comment or someone will add a third state. |

**Behaviour** (in this order):

1. `leases.sweep(now)` — for each expired target, `store.setInsertAnalysisArmed(..., armed: false, owner: .control)`.
2. Parse params. A parse failure throws **before any mutation** (no partial state).
3. `arm == true`: `switch store.setInsertAnalysisArmed(trackID:effectID:armed: true, owner: .control)`
   - `.armed` → `leases.renew(target, deadline: now + defaultTTL)`; read `store.insertAnalysis(...)`; a `nil` here is a can't-happen (the arm just succeeded) — throw `ProjectError.engineUnavailable` rather than fabricate a floor.
   - `.trackNotFound(id)` / `.effectNotFound(id)` → throw the existing `ProjectError` cases (existing messages).
   - `.unavailableHeadless` **or** `.unsupported` → throw `ProjectError.engineUnavailable` ("audio engine not available", `MediaImporting.swift:272-273`). One wire message for both is deliberate — the agent-visible fact is identical — but the store-level distinction is what keeps `cap: 0` out of the cap message, and L12 pins it.
   - `.refusedCapFull(cap)` → throw the **new** `ProjectError.spectrumTapsFull(Int)`, modelled on `chainFull` (`MediaImporting.swift:24`, message at `:216-218`), message text — exact wording is contract:
     `"too many spectrum taps — at most \(cap) inserts can be measured at once; release one with fx.spectrum {arm:false} (or close an EQ card) and retry"`
4. `arm == false`: validate the same way (a typo'd id still refuses), read once if a reading is available, then release the `.control` owner and drop the lease. A target that was not armed is a **benign success**, not an error (mirrors the engine's disarm). Response has `armed: false`.

**Response** = `try JSONValue(encoding: snapshot)` (the *same* encoder call `mixer.masterAnalysis` uses at `Commands.swift:1496`) merged with three keys:

```
bands[24], levelDB, peakDB, centroidHz, flux, correlation, width, balance,   // snapshot, verbatim
armed:        Bool     // the CONTROL-PLANE LEASE is held as of this response
tapPoint:     String   // "postInsertPreFader" | "postInsertPostFader"
leaseSeconds: Double   // 3 — the full TTL, renewed by every arm:true call
```

Rules that must not be softened:

- **Never return floor bands alongside a refusal.** Refusals are errors. The engine's nil-vs-`.floor` distinction (`EngineProtocol.swift:947-953`) exists precisely so an unarmed tap cannot masquerade as a live silent meter; the wire must not undo it.
- `levelDB`/`peakDB` casing is the wire contract (the roadmap line's `levelDb` is shorthand). Reusing the snapshot encoder is what guarantees a `fx.spectrum` response and a `mixer.masterAnalysis` response are diffable field-for-field.
- On `arm:false` with nothing armed, emit `armed:false` + `tapPoint` + `leaseSeconds` and **no analysis fields**.

**D5 rationale (deviation from the roadmap's `{trackId?}`).** Every other `fx.*` verb requires `trackId` and takes `"master"` (`Commands.swift:1256-1330`). An optional `trackId` meaning "master" would be a **second sentinel convention** for the same concept, and `parseFXTarget()` — the ONE home — would be bypassed. Consistency wins; the roadmap line's `?` was shorthand, not a decision.

---

## 6. MCP tool — `fx_spectrum`

`mcp-server/src/server.ts`, registered beside the other `fx_*` tools. Schemas are auto-`.strict()` by the wrapper at `server.ts:102`, so unknown-key rejection at the boundary is structural — the gate just has to exercise it.

```ts
inputSchema: {
  trackId: z.string().min(1).describe('Id of the track or bus that owns the effect, from project_snapshot, OR "master" for the master output chain.'),
  effectId: z.string().min(1).describe("Id of the effect to measure, from fx_add's result or project_snapshot."),
  arm: z.boolean().optional().describe("Default true: arm (or renew) the 3-second measurement lease and read. False: read one last time and release the tap immediately."),
}
```

The description must teach, at minimum:

1. What the numbers are — point at `mixer_master_analysis` for the field-by-field meaning rather than restating it (one home for that copy).
2. **`tapPoint`**: a strip insert is measured **before** that track's fader, so moving the fader does not move the curve; a master insert is measured **after** the master fader. Comparing the two without reading `tapPoint` is how a user concludes the meter is broken.
3. The lease: 3 seconds, renewed by each call with `arm` defaulting true; the tap releases itself if you stop polling; at most 8 inserts can be measured at once and the 9th is refused, never evicted.
4. **Poll at 5–30 Hz.** Below ~12 Hz the tap's ring drops its oldest frames, so peak release and flux smoothing lag wall-clock. A freshly armed tap honestly reads the floor for ~43 ms.
5. That the reading is measured **after** the named insert, so it shows what that EQ/compressor is producing, not what it receives.

**Copilot catalog.** Add `fx.spectrum` to `Sources/DAWControl/CopilotCatalog.swift` (the m21-b2 law: a new user-facing capability must be visible to the in-app Copilot — the same reason `mixer.liveLoudness` is in the curated set at `CopilotCatalog.swift:657`). Count pin `Tests/DAWControlTests/CopilotCatalogTests.swift:70` moves **67 → 68**.

---

## 7. Implementation plan

Ordered; each step compiles and tests green on its own.

**S1 — DAWCore: the target key (one home).** New `Sources/DAWCore/InsertSpectrumOwnership.swift`:
```swift
public struct InsertAnalysisTarget: Hashable, Sendable {
    public let trackID: UUID?
    public let effectID: UUID
    public init(trackID: UUID?, effectID: UUID)
}
public enum InsertAnalysisOwner: Hashable, Sendable { case ui, control }
public enum InsertArmOutcome: Equatable, Sendable {
    case armed                 // arm:true succeeded (or was already held by this owner)
    case released              // arm:false succeeded — NEVER reuse .armed here
    case trackNotFound(UUID)
    case effectNotFound(UUID)
    case refusedCapFull(cap: Int)
    case unsupported           // engine present but cannot tap inserts (cap 0)
    case unavailableHeadless   // no engine at all
}
```
Then in `Sources/DAWEngine/PlaybackGraph.swift:20-23` replace the 3-line `struct InsertAnalysisKey` with `typealias InsertAnalysisKey = InsertAnalysisTarget`. The memberwise labels are identical, so all ~40 engine-test call sites keep compiling — the compiler verifies the move. *Fallback if this fights access control:* keep both structs and add a field-parity test; do not leave two silently-diverging definitions unpinned.

**S2 — DAWCore: the cap, honestly.** Add `var maxArmedInsertAnalysis: Int { get }` to `AudioEngineControlling` with a default of `0` in the extension at `Sources/DAWCore/EngineProtocol.swift:840` — "an engine that cannot tap inserts measures zero at once," matching the existing no-capability defaults at `:947-958`. `AudioEngine` returns its existing `Self.maxArmedInsertAnalysis`. **No second home for the number 8.**

**S3 — DAWCore: `ProjectStore` ownership.** In `Sources/DAWCore/ProjectStore.swift:1185-1209`:
```swift
private var insertAnalysisOwners: [InsertAnalysisTarget: Set<InsertAnalysisOwner>] = [:]

@discardableResult
public func setInsertAnalysisArmed(trackID: UUID?, effectID: UUID,
                                   armed: Bool, owner: InsertAnalysisOwner) -> InsertArmOutcome
```
- No `owner` default. A default lets a call site join the wrong slot silently.
- Order for `armed == true`, and **the order is load-bearing**:
  1. `guard let engine else { return .unavailableHeadless }`
  2. `guard engine.maxArmedInsertAnalysis > 0 else { return .unsupported }` — **this branch is why `cap: 0` can never reach the cap message.** Every fake in the ~12 `DAWControlTests` suites conforming to `AudioEngineControlling` inherits the no-capability defaults (`EngineProtocol.swift:947-958`), so a present-but-incapable engine is the *default* configuration a control test hits; without this guard it would classify as `.refusedCapFull(cap: 0)` and the wire would emit "at most 0 inserts can be measured at once."
  3. Model lookup: track exists → else `.trackNotFound`; effect on that track (or on `project.masterEffects` when `trackID == nil`) → else `.effectNotFound`.
  4. `engine.setInsertAnalysisArmed(...)` false → `.refusedCapFull(cap: engine.maxArmedInsertAnalysis)`.
  5. Insert the owner → `.armed`.
  **Steps 1–3 are what make the cap message true.** An engine present, capable, with the model entry valid but the strip not yet built also lands in `.refusedCapFull`; the 9th-arm gate leg (L3) arms 8 *real live* inserts, so the message is true there. Say this in the doc comment.
- `armed == false`: same validation, then `insertAnalysisOwners[target]?.remove(owner)`; call the engine's disarm **only when the set becomes empty**; return **`.released`**. Do **not** reuse `.armed` — a `switch` accepts it silently, and this whole item exists because of a silent lie in this same API.
- Rewrite the `insertAnalysis` doc comment with the §1 invariant verbatim; rewrite `EngineProtocol.swift:612-625` the same way and fix its unconditional "pre-fader" claim.

**S4 — DAWApp: three call sites.** `Sources/DAWApp/DAWProApp.swift:1288-1310` — pass `owner: .ui`, and map the outcome to the existing `Bool` at `:1295` (`if case .armed = outcome`). One line each; behaviour unchanged. **No other app change.**

**S5 — DAWCore: `InsertSpectrumTapPoint`.** New `Sources/DAWCore/InsertSpectrumTapPoint.swift` per §4.1 (`fileprivate init`, static constants, `forInsert(trackID:)`).

**S6 — DAWCore: the new error.** `ProjectError.spectrumTapsFull(Int)` in `Sources/DAWCore/MediaImporting.swift` beside `chainFull` (`:24`), message per §5 at `:216-218`'s style, with the same "exact wording is contract" comment.

**S7 — DAWControl: the lease.** New `Sources/DAWControl/InsertSpectrumLeases.swift` — `@MainActor`, `[InsertAnalysisTarget: Deadline]`, injectable now-provider, `static let defaultTTL: Duration = .seconds(3)`, methods `sweep(now:release:)`, `renew(_:now:)`, `release(_:)`, `isHeld(_:now:)`. `sweep` takes the release action as a closure so the lease type never imports the store's semantics.

**S8 — DAWControl: the command.** `Sources/DAWControl/Commands.swift` — append `"fx.spectrum"` at the **END** of the `allCommands` array (`:175`, the additive-at-end law), and add the `case "fx.spectrum":` handler beside the other `fx.*` cases with the full teaching doc comment (§5).

**S9 — Copilot catalog.** `Sources/DAWControl/CopilotCatalog.swift` — one entry (§6).

**S10 — MCP.** `mcp-server/src/server.ts` — `fx_spectrum` tool (§6) → `bridge.send("fx.spectrum", args)`.

**S10b — MCP test file.** New `mcp-server/test/fx-spectrum.test.ts`, modelled on `mcp-server/test/mixer-master-analysis.test.ts`. `npm test` is a glob, so the file is picked up as soon as it exists — but nothing else creates it, and L8's MCP half has no artifact behind it until this step runs.

**S11 — count pins.** `161 → 162` at **all twelve** sites:
`Tests/DAWControlTests/{RenderCommandTests:683, TrackReorderCommandTests:174, LiveLoudnessCommandTests:78, VoiceListCommandTests:35, AUParamCommandTests:171, RenderOutputFormatCommandTests:287, ZeroParamVerbRejectionTests:286, MIDIFileExportCommandTests:48, SoundBankCommandTests:433, ClipFitToContentCommandTests:169, ReferenceCommandTests:131, MIDIFileImportCommandTests:67}`.
Plus `mcp-server/test/integration.test.ts:290` **164 → 165** and `CopilotCatalogTests.swift:70` **67 → 68**.

**S12 — docs.** `docs/ROADMAP.md` line 457 ticked with the measured close-out; `CHANGELOG.md`; `docs/ARCHITECTURE.md` "Key future decisions" entry (added by this design).

---

## 8. Gate design — legs and the mutation that reddens each

**Audit first (this trap has been paid for once already, at r2b).** Two discriminators the roadmap asks for **already exist**; extend them, do not clone them:
- `Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift:180-200` — `expectLive(...)` already asserts `bands.firstIndex(of: peak) == MasterMixAnalyzer.bandIndex(containing: toneHz)`. **`bandIndex(containing:)` is the band oracle; never hardcode an index.**
- `:295-341` and `:373-418` — the 0.0 dB / 6.0206 dB fader deltas. **Extend these two legs with "and `InsertSpectrumTapPoint.forInsert(trackID:)` agrees"** rather than creating a second home for those numbers.

New suite: `Tests/DAWControlTests/FXSpectrumCommandTests.swift`, modelled on `LiveLoudnessCommandTests.swift` (fake conforming to `AudioEngineControlling`). **The fake must host a REAL `InsertSpectrumTap` + `MasterMixAnalyzer`** (`@testable import DAWEngine`; `DAWControlTests` already depends on DAWEngine, `Package.swift:129`): `setInsertAnalysisArmed` allocates a real tap, the test writes a real injected tone through `tap.write(buffers:frameCount:)` (`InsertSpectrumTap.swift:203`), `insertAnalysis` returns `tap.drainAndSnapshot()`. What is faked is **only the graph topology**, which r2b already pins. **Never stub a bands array** — that turns the peak-band leg into a scrape.
**Budget ~25 lines of scaffolding for this**: `tap.write(buffers:frameCount:)` takes an `UnsafeMutableAudioBufferListPointer`, and r2b's `Scratch` helper lives in `DAWEngineTests` and is not reachable from `DAWControlTests`, so the new suite needs its own deinterleaved 2-channel buffer-list setup. That is scaffolding, not a second home for anything — but the **band oracle must remain `MasterMixAnalyzer.bandIndex(containing:)`**.

| # | Leg | Mutation that must redden it |
|---|---|---|
| L1 | Arm → feed ≥ 200 ms of a 1 kHz tone → response `bands` are non-floor **and the peak band == `MasterMixAnalyzer.bandIndex(containing: 1000)`**. | Router returns `.floor` instead of the drained snapshot; or reads the wrong `effectId`; or drops the drain call. |
| L2 | Silent (no frames written) armed tap → response bands are **exactly** the floor, `armed:true`. | Router substitutes a "no data" sentinel, or omits fields, or errors. |
| L3 | Arm 8 real live inserts, then a 9th → error whose message **contains the cap number and the word for how to release one**. `allCommands` unchanged, no 9th owner recorded. | Change the store to return `.armed` on engine refusal; change the message to omit the cap; make the store hold its own cap constant. |
| L4a | **Lease expiry stops reporting `armed`**: arm, advance the injected clock past TTL, call again with `arm:false` → `armed:false`. | Delete the deadline comparison in `sweep`. |
| L4b | **Lease expiry frees a cap slot**: fill the cap, expire one, arm a new target → succeeds. | Delete the `sweep` **call** at the top of `fx.spectrum` (L4a still passes — that is why these are two legs). |
| L5a | **Stomp, wire → UI**: `.ui` arms; `.control` arms the same target; expire the lease; `.ui` still reads a live snapshot. | Make the store's disarm unconditional (drop the empty-set check). |
| L5b | **Stomp, UI → wire**: `.control` arms; `.ui` arms then releases; `.control` still reads a live snapshot. | Make `DAWProApp.releaseInsertSpectrum` bypass the owner (i.e. the pre-r4 unconditional call). |
| L6 | `#expect(InsertSpectrumLeases.defaultTTL == .seconds(3))` — a literal pin, separate from every behavioural leg. | 3 s → 300 s. (Without L6 that mutation passes everything, because L4a/L4b drive the injected clock.) |
| L7 | Unknown `trackId` → `trackNotFound`; unknown `effectId` → `effectNotFound`; **and no owner was recorded and no engine arm happened** (assert the fake's arm count is 0). | Move the model lookup after the engine call; or record the owner before validating. |
| L8 | `rejectUnknownKeys` — an unknown key names the key and the verb; MCP side: a `.strict()` schema rejects it at the boundary before any wire traffic. | Drop a key from the allow-list array (the sweep in `ZeroParamVerbRejectionTests` also covers the missing-guard direction automatically). |
| L9 | **Label agreement**: `InsertSpectrumTapPoint.forInsert(trackID: someTrack).wireValue == "postInsertPreFader"`, `forInsert(trackID: nil)` == `"postInsertPostFader"`, **and** `EQCurveEditorModel.curveHelp(for: <track target>, isMeasuring: true)` contains "BEFORE the fader". Plus the two r2b legs extended per the audit note. | Flip the mapping in `forInsert`; or edit the track help string. |
| L10 | *(recommended, gated on §4.5)* Strip insert with `isMuted: true` — measure the delta the way `:295-341` measures the fader. Only if the MCP description is to claim mute behaviour. | Move the mute application upstream of the chain host. |
| L12 | **Headless / no-capability**: a store with `engine == nil`, and separately a fake reporting `maxArmedInsertAnalysis == 0`, both refuse with `engineUnavailable` — and **neither message contains a cap number**. | Return floor bands instead of throwing; or delete the `maxArmedInsertAnalysis > 0` guard so the second case emits "at most 0 inserts". |
| L11 | Wire/MCP/catalog counts: `allCommands.count == 162`, `fx.spectrum` is **last**, MCP tools 165, catalog 68. | Insert the command anywhere but the end; forget the MCP tool. |

**Anti-vacuity discipline (house law).** L1's assertion is an AND of "non-floor" and "peak on the tone's band" — plant a **disjoint** mutation for each half (a floor-returning router for the first; an off-by-one band oracle for the second). Do not let one needle coast on the other's match.

**Running the suite:** `./scripts/test.sh --filter FXSpectrumCommandTests` — the **type name**, never the `@Suite` display string (a display string runs 0 tests at exit 0).

---

## 9. RT-safety and Xcode

- **Nothing in this design touches the render thread.** The tap's render-side half is unchanged: two bounded `memcpy`s into a preallocated SPSC ring. The owner set, the lease, the outcome enum, and the tap-point label are all `@MainActor` control-plane state.
- **The SPSC contract is preserved by isolation, not by convention.** Both consumers are `@MainActor`; there is still exactly one consumer *thread*. This is the load-bearing sentence — put it in the doc comments (§1).
- **No new allocation on any audio path.** The only new allocation is a dictionary entry per armed target, on the main actor, bounded by 8.
- **No Xcode-only work.** No entitlements, no AUv3, no signing, no bundling. `swift build` + `./scripts/test.sh` cover the whole item.
- **Port discipline:** any live smoke test uses staging **17695**. Port 17600 is the user's live app and is never touched.

---

## 10. What this design deliberately does not do

- No fan-out, coalescing, or snapshot memo (§1).
- No change to `AudioEngine`, `PlaybackGraph`, `EffectChainProcessor`, `InsertSpectrumTap`, or `MasterMixAnalyzer` beyond the `InsertAnalysisKey` typealias and the new protocol cap accessor.
- No change to `project.snapshot` — raw spectrum data stays off the always-on wire (the `MasterScopeFrame` precedent).
- No change to any pinned `curveHelp` string.
- No new always-on timer anywhere; the lease is lazily swept, by definition.
