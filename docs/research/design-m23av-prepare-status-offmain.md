# m23-av — AU prepare status off the main actor

**DETECTION AND HONESTY ONLY. This item does not unwedge anything. It makes a wedge LEGIBLE.**

Design doc for ROADMAP item m23-av, route **(a)** only. Route (b) (out-of-process AUv3
hosting) is explicitly OUT OF SCOPE and no close-out may read this as delivering it.
See §10.

Design-only cycle: **no source or test file was modified while writing this.** Every
kill-mutation in §8 is therefore stated as UNVERIFIED with an explicit confidence and
reason — see the warning at the head of §8.

Related: `docs/research/design-m23au-viewresolver-deadline.md` (the sibling primitive),
ROADMAP m23-at (the deadline that decides on wall time), m18-b (`MainActorLiveness`, the
precedent this copies).

---

## 1. THE FINDING (this is what shapes the item)

**`engine.auPrepareStats` is NOT answerable during the wedge it would be most useful in.**
Two independent reasons, both read from the code, both sufficient on their own:

1. **The router hop.** `ControlServer.dispatch` reaches the router through
   `Task { @MainActor [router] in … }` (`Sources/DAWControl/ControlServer.swift:110`).
   The handler (`Sources/DAWControl/Commands.swift:1852-1854`) calls
   `store.auPrepareStats()` on `@MainActor ProjectStore`
   (`Sources/DAWCore/ProjectStore.swift:1359`) → `@MainActor AudioEngine.auPrepareStats()`
   (`Sources/DAWEngine/AudioEngine.swift:2072`) → `@MainActor AUHostRegistry.prepareStats()`
   (`Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:147`). `AudioEngineProtocol` is
   `@MainActor` (`Sources/DAWCore/EngineProtocol.swift:343`); `AUHostRegistry` is
   `@MainActor` (`AUHostRegistry.swift:37`). Every hop needs the actor the wedged plug-in
   is holding.

2. **The intercept refuses it before that.** `ControlServer.wedgeIntercept`
   (`ControlServer.swift:141-156`) allow-lists exactly ONE verb, `engine.watchdogStatus`.
   Everything else — `engine.auPrepareStats` included — returns
   `wedgeTeachingError(...)` and never reaches the router at all.

So today, during a Surge-XT-class wedge, the only thing the wire can say about AU prepare
is *"main actor has been unresponsive for N s"*. It cannot say **which** slot, **which
component**, **how long that prepare has been in flight**, or **that the prepare's own
deadline has already passed**. m23-at made the deadline DECIDE on wall time; the decision
is then published by `status[id] = .failed(…)` at `AUHostRegistry.swift:810`, inside a
`@MainActor` function, so during a wedge the decision exists and is unreachable.

### 1.1 Why `DeadlineRace` cannot close this

`DeadlineRace.run` is `nonisolated` and resolves `.timedOut` from a `Task.detached`
(`Sources/DAWCore/DeadlineRace.swift:51-85`) — correct, and unaffected. But its CALLER,
`AUHostRegistry.performPrepare` (`:640`), is `@MainActor`. The continuation resume hands
control back to a main-actor function, so `performPrepare` cannot proceed past its `await`
until the main actor is free. When the wedge is *inside* `instantiator` — i.e. the work
itself holds the actor — the sequence is:

```
t0            main actor: status[id] = .pending ; DeadlineRace.run(...) armed
t0            work task hops @MainActor, calls instantiator, plug-in SPINS
t0+budget     detached deadline resolves .timedOut          <-- DECIDED, off-main
t0+budget..T  main actor still held by the plug-in          <-- NOTHING OBSERVABLE
T (minutes)   plug-in returns; performPrepare resumes; status[id] = .failed("timed out")
```

The window `[t0+budget, T]` is the whole of m23-av. Leg 1 of `DeadlineRaceTests` proves
the SIBLING-hog case (a separate task holds the actor while `work` is trivial); no
`DeadlineRace` test can reach the work-holds-the-actor case, because a nonisolated caller
never needs the actor to resume. The gap is a property of `AUHostRegistry`'s state being
main-actor-isolated, not of the primitive.

---

## 2. THE DECISION

**Add ONE lock-protected, `nonisolated` in-flight ledger to `AUHostRegistry` — the sole
home of a fact that has no home today: "a prepare body for slot S (kind, id, component)
has been armed since T against a deadline of D and has not yet published an outcome."
Derive `overdue` AT READ TIME from an injected monotonic clock; never write it off-main.
Publish it two ways, from one producer: as an additive `inFlight` field on the existing
`EngineAUPrepareStats`, and as the payload of a widened `ControlServer.wedgeIntercept`
allow-list entry for `engine.auPrepareStats`. Do NOT migrate `status`, `effectStatus`,
`attempted`, `effectAttempted` or the four counters off the main actor.**

Five properties this buys, each named because a reviewer will ask:

- **One home, structurally.** The in-flight fact is new. Nothing else in the tree stores
  it, so there is no second cache to diverge from. §4 walks the one-home audit slot by slot.
- **No second computation.** The healthy path and the wedged path call the SAME
  `ledger.snapshot(now:)`; the healthy path embeds its result in `prepareStats()`.
- **No new writer thread.** Arming and disarming happen on the main actor at exactly one
  site each, BEFORE and AFTER the wedge window. The off-main side only READS.
- **`DeadlineRace` is untouched.** An `onTimeout` callback would have created a second
  publisher of the same outcome and would have reopened the primitive m23-au just
  consolidated (§3, alternative B).
- **Zero new wire verbs.** Additive fields on an existing verb (§5), so wire/MCP/catalog
  counts stay 171 / 174 / 74.

The shape is `MainActorLivenessMonitor`'s, deliberately: pure state + injected time,
`NSLock` (macOS 14 floor — `Synchronization.Mutex` is 15+), a `snapshot()` any thread can
take without touching the main actor.

---

## 3. THE TWO STRONGEST ALTERNATIVES, AND WHY THEY LOSE

### Alternative A — "Shape S": migrate ALL of `prepareStats()`'s inputs off-main

Move `status`, `effectStatus`, `attempted`, `effectAttempted`, the four counters and
`knownTrackIDs`/`knownEffectIDs` into the lock-protected store; make `prepareStats()`
`nonisolated`; make `status` a computed view with no stored backing (divergence
unrepresentable, the `ArrangeDropSnap` grade). During a wedge the verb then returns a
COMPLETE `EngineAUPrepareStats`.

**Why it loses.** Its entire justification was "otherwise the wedged path needs a second
producer of `EngineAUPrepareStats`". That premise is false, and the precedent it claims to
protect refutes it: the wedged `engine.watchdogStatus` answer at `ControlServer.swift:147-153`
does **not** encode an `EngineWatchdogStatus`. It hand-builds
`.object(["mainActor": .object([...])])` and omits every main-actor-produced field, under
the rule stated at `:131-137` — *"rather than dress a stale cache as live data they are
honestly OMITTED"*. So a partial wedged object is the house answer, not a compromise.

And it carries a **live-audio hazard, not a diagnostics one**: `knownTrackIDs`
(`AUHostRegistry.swift:431`) is `Set(status.keys) ∪ instruments.keys ∪ attempted.keys`,
and `AudioEngine.swift:1590` uses it as a GC pass —
`for id in knownTrackIDs where auTracks[id] == nil { releaseInstrument(forTrack: id) }`.
`instruments` holds the live `HostedAUInstrument` objects and CANNOT move off-main. Any
off-main recomputation of that set must drop the `instruments.keys` term. It is true by
construction today that `instruments.keys ⊆ attempted.keys` (`:671` precedes `:805`), but
if that ever stops being true a hosted AU leaks **and keeps rendering**. Trading an
audio-lifecycle invariant for a fuller diagnostics payload is a bad trade.

Rejected. If someone later wants the full payload during a wedge, that is its own item and
it must carry a test for the `instruments.keys ⊆ attempted.keys` invariant.

### Alternative B — `DeadlineRace.run(timeout:onTimeout:)`, writing the verdict off-main

Give the primitive an optional `@Sendable () -> Void` fired on the detached deadline task,
and have `AUHostRegistry` write `.failed("timed out")` into an off-main store from there.

**Why it loses.** It creates **two publishers of one outcome**: the off-main callback and
the eventual main-actor `status[id] = .failed(…)` at `:810`. They agree today only because
both spell the same string; nothing makes divergence unrepresentable, and a future edit to
one message silently forks the answer. That is the "second cache wearing a different hat"
failure mode, exactly. It also reopens `DeadlineRace` — the primitive m23-au just proved
has ONE home (`ResumeGate` occurs in `Sources/` only in `DAWCore/DeadlineRace.swift`) —
to add a side channel used by one of its two call sites.

Derive-at-read has none of this: the ledger records **evidence** (armed at T, deadline D)
and computes the **verdict** in one function, on demand, and there is no writer to race.

### Also considered, briefly

- **A bare new verb `debug.auPrepareInFlight`.** Rejected under the additive-only wire
  rule's spirit: a second verb answering a question an existing verb already claims to
  answer is the discoverability failure m18-b explicitly avoided ("Same verb, one
  discoverable surface, zero new commands", `Commands.swift:1795-1799`). See §5.
- **Retaining a "last prepare that timed out" record in the ledger** (the
  `lastWedgeDurationSeconds` analogue). Rejected: `status[id] = .failed("… timed out …")`
  already retains that fact permanently and is already on the wire via
  `EngineAUPrepareStats.TrackEntry.status`. A retained copy would be a second home for a
  fact that has one. **This is a case where the one-home rule PREVENTS a feature; that is
  the rule working.**

---

## 4. WHAT MOVES OFF-MAIN, WHAT MUST NOT, AND WHAT A STALE READER MAY CONCLUDE

### 4.1 The boundary

| Thing | Stays `@MainActor` | Goes off-main | Why |
|---|---|---|---|
| `AUAudioUnit` instances, `instruments`, `effects`, `HostedAUInstrument`/`Effect` | YES | — | AU property access is main-thread-only. Non-negotiable, and it is the reason route (b) exists. |
| `status`, `effectStatus` (published outcome) | YES | — | Published by the main actor; a wedged reader legitimately cannot see a change that has not happened. |
| `attempted`, `effectAttempted` (`PrepareKey`) | YES | — | The idempotency comparison home. Moving it buys nothing for legibility. |
| The four m23-br-1 counters | YES | — | Same. |
| `knownTrackIDs` / `knownEffectIDs` | YES | — | Depends on `instruments`/`effects`. §3-A. |
| **In-flight arming records (NEW)** | — | **YES** | The one fact with no home; a VALUE (`UUID`, `Double`, `String`), trivially `Sendable`. |

Nothing that goes off-main is a copy of anything. The record's `component` string is a
point-in-time snapshot of the arming EVENT (like a log line), not a mirror of live state:
it is written once at arm, never updated, and deleted at disarm. It is not a second home
for `attempted[id].component` any more than a log line is.

### 4.2 What an off-main reader MAY conclude from a snapshot

- "A prepare for slot S (kind, id, component) was armed `startedSecondsAgo` ago against a
  `deadlineSeconds` deadline and **has not published an outcome yet**."
- When `overdue`: "its wall-clock deadline has passed, so `DeadlineRace` has already
  resolved `.timedOut` for it, and the registry has not been able to publish that."
- When a slot is ABSENT: "no prepare body for that slot is currently between arming and
  publication." (Not: "that slot is fine".)

### 4.3 What an off-main reader MAY NOT conclude

- **NOT "the AU failed."** The work runs to completion after a timeout
  (`DeadlineRace.swift:47-48`); the eventual main-actor publication is
  `.failed("… timed out …")` regardless of whether the work later succeeded. `overdue`
  means *the deadline passed*, not *the component is broken*.
- **NOT "the main actor is wedged."** A prepare can be overdue on a perfectly responsive
  main actor (the m23-at second-order regime: under load, a GM prepare measured
  17.3–26.9 s). The wedge question has its own home — `MainActorLivenessSnapshot` — and
  the two must be read together, which is why §5's wedged payload carries both.
- **NOT anything about `status[id]`.** The ledger does not mirror it. A reader wanting the
  published status must wait for the main actor.
- **NOT anything about AUDIO.** *The render thread runs straight through a main-actor
  wedge — that independence is a feature (m18-b). A wedged app whose instruments are
  already `.ready` keeps making sound.* An overdue prepare means one track will render the
  silent placeholder; it does not mean playback stopped.

### 4.4 Real-time safety

The ledger is touched by: the main actor (arm/disarm, and the healthy `prepareStats()`
read), the control server's private `dispatch` queue (`ControlServer.swift:12`), the
`MainActorLivenessMonitor` timer queue if §6 lands, and test readers. **Never the render
thread.** The render path reaches AU state only through `HostedAUInstrument`'s captured
blocks; `preparedInstrument`/`preparedEffect` (`AUHostRegistry.swift:375, :469`) are
`@MainActor` graph-build accessors and touch neither `status` nor the ledger. No
allocation, lock, or blocking call is added to any render callback. This item adds nothing
to `PlaybackGraph` or any render block.

---

## 5. THE WIRE: `engine.auPrepareStats` IS FIXED IN PLACE. NO NEW VERB.

**Decision: fix the read path of the existing verb. Do not add a bare read verb.**

Justification, in the project's own terms: the additive-only rule forbids renaming live
commands and prefers extending them; m18-b set the exact precedent for this exact problem
("ADDITIVE … `mainActor: {responsive: true}` rides every response produced HERE … Same
verb, one discoverable surface, zero new commands" — `Commands.swift:1789-1799`). A second
verb would also mean two answers to "what is the AU host doing", which is the one-home
failure at the wire tier. Wire/MCP/catalog counts stay **171 / 174 / 74**; the existing
MCP tool `engine_au_prepare_stats` (`mcp-server/src/server.ts:4501`) gains fields without
a code change beyond its description.

### 5.1 Healthy response (main actor available) — ADDITIVE

`EngineAUPrepareStats` gains `inFlight: [InFlightEntry]` (default `[]` in the memberwise
init so `.idle` at `Model.swift:2541` and the four test constructors in
`Tests/DAWControlTests/EngineAUPrepareStatsCommandTests.swift` keep compiling), and the
handler mirrors the watchdog's `mainActor` echo:

```json
{ "instrumentPrepares": 3, "instrumentReleases": 1,
  "effectPrepares": 0, "effectReleases": 0,
  "tracks": [ … ], "effects": [ … ],
  "inFlight": [ {"slot":"instrument","id":"<uuid>",
                 "component":{"type":"aumu","subType":"VmbA","manufacturer":"VmbA"},
                 "startedSecondsAgo":47.2,"deadlineSeconds":10.0,"overdue":true} ],
  "mainActor": {"responsive": true} }
```

`inFlight` is sorted by `(slot, id)` — the same positional-diff discipline `tracks` and
`effects` already carry (`AUHostRegistry.swift:155, :163`).

### 5.2 Wedged response (queue tier, `wedgeIntercept`)

Modelled byte-for-byte on the watchdog rule at `ControlServer.swift:147-153`: emit ONLY
what an off-main producer can honestly produce; OMIT every main-actor-produced field
rather than emit zeros.

```json
{ "mainActor": {"responsive": false, "wedgedForSeconds": 63.4},
  "inFlight": [ {"slot":"instrument","id":"<uuid>",
                 "component":{"type":"aumu","subType":"VmbA","manufacturer":"VmbA"},
                 "startedSecondsAgo":61.9,"deadlineSeconds":10.0,"overdue":true} ] }
```

`instrumentPrepares` / `instrumentReleases` / `effectPrepares` / `effectReleases` /
`tracks` / `effects` are **absent, not zero**. `mainActor.responsive:false` is the flag a
client uses to know it received the partial form — which is exactly why §5.1 adds
`mainActor:{responsive:true}` to the healthy form: the discriminator is always present.

`inFlight` entries are produced by the SAME `AUPrepareLedger.snapshot(now:)` and encoded
from the SAME `Codable` type. One producer, one shape, two response envelopes.

### 5.3 Teaching error, unchanged for everything else

Every other verb keeps `wedgeTeachingError`. Its text should gain the new pointer (it
already names `engine.watchdogStatus`); this is a string change to
`ControlServer.swift:161-166` and needs its existing test updated:

> `… — the app UI is wedged; engine.watchdogStatus reports liveness and
> engine.auPrepareStats reports any AU prepare still in flight; other commands cannot run
> until it recovers.`

---

## 6. WHAT THE WATCHDOG REPORTS, AND WHEN (Q4)

**What already polls this: nothing in-process.** `EngineWatchdog`
(`Sources/DAWEngine/EngineWatchdog.swift:28`) is the RENDER-side stall detector and is
irrelevant here. `engine.auPrepareStats` is read only by
`scripts/gates/m20e-flip-path.mjs` and the MCP tool — i.e. on demand, by an agent. So
without §6 the honest statement is *"the fact becomes ANSWERABLE during a wedge"*, not
*"the app reports it"*.

**Phase 3 (recommended, separable): one breadcrumb line, off-main, once per episode.**
`MainActorLivenessMonitor` already owns the only off-main 1 s tick with a breadcrumb sink
(`MainActorLiveness.swift:261-273, :295-312`), writing to
`~/Library/Logs/DAWPro/main-actor-wedge.log`. Give its `init` an additional optional
`@Sendable () -> [EngineAUPrepareStats.InFlightEntry]` probe (default nil → byte-identical
current behaviour) and have `handleTimerTick` write, off-main, one line per slot the first
time that slot goes overdue:

```
2026-08-03T12:41:09Z AU-PREPARE-OVERDUE instrument <uuid> aumu/VmbA/VmbA overdue by 51.9 s (deadline 10.0 s)
```

The once-per-episode latch belongs in the ledger (`declaredOverdue: Set<Key>`, cleared on
disarm) — the `MainActorLiveness.wedgeDeclared` shape, and the line formatter is a pure
static function next to it, testable headless like `MainActorLiveness.wedgeLine`. Putting
the latch in the monitor would be a second home for "have we already reported this".

Co-locating AU-prepare lines with wedge lines in ONE chronological file is deliberate: the
post-mortem question is "was the app wedged, and was an AU prepare the cause", and that is
answered by adjacency. Module-wise this is a closure injection, so DAWControl gains no
dependency on DAWEngine (it has none today — `Package.swift:85` is
`["DAWCore", "AIServices"]`), which is why the entry type must live in **DAWCore**.

Note for the implementer: in a Swift test process `defaultPrepareTimeout` is 60 s
(`AUHostRegistry.swift:287`), so the suite will not spray breadcrumbs.

---

## 7. IMPLEMENTATION PLAN

Route: `audio-dsp-engineer` (AU-host lifecycle) with `daw-architect` review, per the
m23-at routing. Phases are independently landable; Phase 3 is separable.

### Phase 0 — pin the defect first (do this BEFORE writing production code)

Write gate leg **E1** (§8) against the CURRENT tree and watch it fail. It must fail
because the read is main-actor-gated, not because a symbol is missing. This is the m23-au
B0 discipline: measure the premise before designing around it.

### Phase 1 — the ledger and the arming

1. **NEW** `Sources/DAWCore/Model.swift` — nested in `EngineAUPrepareStats`:
   `public struct InFlightEntry: Codable, Sendable, Equatable` with
   `slot: String` (`"instrument"` | `"effect"`), `id: String`,
   `component: AudioUnitComponentID?`, `startedSecondsAgo: Double`,
   `deadlineSeconds: Double`, `overdue: Bool`.
   **`component` MUST be the existing `AudioUnitComponentID`** (`Model.swift:1454`, already
   `Codable`, encoding `{type, subType, manufacturer}`) — VERIFIED by grep. A new string
   spelling like `"aumu/VmbA/VmbA"` would be a second spelling of a live wire concept, i.e.
   the one-home rule violated at the wire tier. It is available at both arm sites as
   `key.component`.
   Add `public var inFlight: [InFlightEntry]` to `EngineAUPrepareStats`, with
   `inFlight: [InFlightEntry] = []` in the memberwise init (keeps `.idle` at `:2541` and
   the four test constructors compiling). Document on the type: `overdue` is the VERDICT,
   the other two are the EVIDENCE, and §4.3's four "may not conclude" clauses.
2. **NEW FILE** `Sources/DAWEngine/AudioUnits/AUPrepareLedger.swift`:
   - `struct AUPrepareLedgerState: Sendable` — the pure, headless, injected-time state
     machine. `arm(slot:id:component:at:deadlineSeconds:)`, `disarm(slot:id:) `,
     `entries(now:) -> [EngineAUPrepareStats.InFlightEntry]` (sorted by `(slot, id)`),
     and (Phase 3) `declareOverdue(now:) -> [InFlightEntry]` with the once-per-episode
     latch. Keyed by `struct Key: Hashable { let slot: Slot; let id: UUID }` —
     **(kind, id), never id alone**: an instrument prepare and an effect prepare run on
     separate chains and CAN be in flight simultaneously (the main actor is free while
     `performPrepare` awaits `DeadlineRace.run`).
   - `final class AUPrepareLedger: @unchecked Sendable` — `NSLock` + state +
     `clock: @Sendable () -> Double` (default
     `Double(DispatchTime.now().uptimeNanoseconds) / 1e9`, mach uptime, which pauses
     across system sleep so a lid-close cannot masquerade as an overdue prepare — the
     EngineWatchdog no-wall-time law). `snapshot()` takes the lock and calls
     `state.entries(now: clock())`. `@unchecked Sendable` justification comment in the
     `DeadlineResumeGate` / `MainActorLivenessMonitor` form.
   - `arm` REPLACES an existing record for the same key (a new prepare body is a new
     attempt). **This deliberately diverges from `MainActorLiveness.recordPing`, which
     keeps the OLDEST anchor** — there, later pings are queued behind the first and must
     not make a wedge look younger; here, `prepareChains` (`AUHostRegistry.swift:107, :442`)
     serialises bodies per id so arm/disarm is strictly nested and a replace can only
     happen if a record leaked. Say this in the doc comment; it will otherwise be
     "corrected" to match the precedent.
3. `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift`:
   - `nonisolated let prepareLedger = AUPrepareLedger()` (a `nonisolated` stored property
     needs a nonisolated default-value expression — `AUPrepareLedger.init` must NOT be
     main-actor-isolated. See probe P1 in §12; this is the one thing that errored).
   - **ARM at exactly one site per kind, where `.pending` is written and the race begins:**
     `:706` (instrument) and `:544` (effect). Arming earlier would leave phantom records
     on the `guard let key … else` bail (`:646-648`), the bank-resolve failure (`:682`)
     and the no-matching-component return (`:700`) — none of which enter a race.
   - **DISARM at exactly one site per kind: the outcome `switch`** — `:794-812`
     (instrument) and `:601-610` (effect), all three cases. **Do NOT also disarm in
     `releaseInstrument`/`releaseEffect`** (`:395, :485`): that would be a second disarm
     home and a race with the resuming prepare. Consequence, stated honestly: if a track
     is deleted mid-prepare the record lingers until the prepare resumes, which under a
     wedge is exactly the reporting behaviour we want.
   - `nonisolated func inFlightSnapshot() -> [EngineAUPrepareStats.InFlightEntry]`
     → `prepareLedger.snapshot()`.
   - `prepareStats()` (`:147`) embeds `inFlight: inFlightSnapshot()`. **One producer.**
4. `Sources/DAWEngine/AudioEngine.swift`:
   `nonisolated public func auPrepareInFlight() -> [EngineAUPrepareStats.InFlightEntry]`
   → `auRegistry.inFlightSnapshot()`. **No declaration change to `auRegistry`** — probe C
   (§12) proves a `nonisolated` method on a `@MainActor` class can read a plain `let` of
   `@MainActor` class type and call a `nonisolated` method on it. `auPrepareStats()` at
   `:2072` is unchanged and picks the new field up for free.
   **No `AudioEngineProtocol` change** — the healthy path already routes through
   `auPrepareStats()`, and the wedged path captures the concrete `AudioEngine` (step 6).

### Phase 2 — the wire

5. `Sources/DAWControl/ControlServer.swift`:
   - `private let auPrepareInFlight: (@Sendable () -> [EngineAUPrepareStats.InFlightEntry])?`
     injected at `init` next to `livenessSnapshot`, same nil-means-no-interception
     contract.
   - **HONESTY HOLE, close it explicitly: when the provider is nil, OMIT the `inFlight`
     key entirely.** Emitting `inFlight: []` would assert *"nothing is in flight"*, which
     the server has no way to know — a lie under a doctrine literally named DETECTION AND
     HONESTY. With the key omitted the wedged answer degrades to exactly the
     `engine.watchdogStatus` payload, which says nothing false. (Considered and rejected:
     falling through to the teaching error — that would also drop the `mainActor` fact,
     which IS knowable.) Pinned by W6.
   - `wedgeIntercept(_:snapshot:inFlight:)` gains the parameter **with NO DEFAULT**, so
     the compiler enumerates call sites (the m23-bp/bq/bs house pattern). Update the five
     existing call sites in `Tests/DAWControlTests/MainActorLivenessTests.swift`
     (`:171, :173, :179, :195, :208`) explicitly.
   - Widen the allow-list to `{engine.watchdogStatus, engine.auPrepareStats}` and build
     the §5.2 payload. Keep the branch structure explicit (two `if`s or a `switch`), not a
     `Set.contains` that would be easy to widen accidentally.
   - Update `wedgeTeachingError` per §5.3 and its test.
6. `Sources/DAWControl/Commands.swift:1852` — add the `mainActor: {responsive: true}` echo,
   the exact four-line mirror of `:1801-1806`, and extend the block comment.
7. `Sources/DAWApp/DAWProApp.swift:2851-2853` — pass
   `auPrepareInFlight: { [engine] in engine.auPrepareInFlight() }`. `engine` is a concrete
   `let engine: AudioEngine` created at `:2433`, well before the server at `:2852`; a
   `@MainActor` class is implicitly `Sendable`, so the `@Sendable` closure compiles
   (probe F, §12). Strong capture is cycle-free on the `livenessMonitor` precedent
   (server → closure → engine; the engine does not reference the server).
8. `mcp-server/src/server.ts:4501-4529` — description only: document `inFlight`,
   `mainActor`, and that the wedged form omits counters. No new tool.

### Phase 3 — the breadcrumb (separable; §6)

9. `AUPrepareLedgerState.declareOverdue(now:)` + `AUPrepareLedger.overdueLine(...)` static
   formatter.
10. `MainActorLivenessMonitor.init` gains the optional probe; `handleTimerTick` writes the
    lines off-main after the existing wedge line.
11. `DAWProApp.swift:2849` — pass the probe.

### Close-out

- Tick `docs/ROADMAP.md` m23-av with the §10 wording.
- `docs/ARCHITECTURE.md` "Key future decisions" — the entry is drafted in §11.
- CHANGELOG.
- Baselines: full `./scripts/test.sh` (**grep `✘` — it exits 0 on failure**), wire counts
  re-measured (expected UNCHANGED at 171 / 174 / 74), forced 0-warning rebuild of the
  changed targets via `rtk proxy`.
- `dist/DAWPro.app` is not rebuilt (user's call); note the gap widens — and note that this
  fix, like m23-at's, exists only in the tree.

---

## 8. THE GATE

> ⚠️ **EVERY kill-mutation below is UNVERIFIED.** This was a design-only cycle; no source
> or test file was modified, so no mutation was applied and no leg was observed red. The
> m23-au precedent is the reason this warning exists: that design's table asserted a
> mutation would redden leg S6, the orchestrator applied it, S6 stayed GREEN and only S8
> caught it. Each row below carries an explicit confidence and the reason for it. **The
> implementing agent must APPLY each mutation and record which leg actually reddened,
> correcting this table in the close-out.**

### 8.1 Pure ledger legs — `Tests/DAWEngineTests/AUPrepareLedgerTests.swift`

Injected time, no sleeps, no CoreAudio — the `MainActorLivenessTests` discipline.

| Leg | Asserts | Kill-mutation | Confidence |
|---|---|---|---|
| **P1** | `arm(at: 0, deadline: 10)`; `entries(now: 9.9)` → `overdue == false`; `entries(now: 10.1)` → `overdue == true`; `startedSecondsAgo == now - armedAt` in both | compute `overdue` as `startedSecondsAgo > 0` | HIGH — direct data flow, single expression |
| **P2** | `disarm` removes the entry; disarming an unarmed key is a no-op | make `disarm` a no-op | HIGH |
| **P3** | an instrument and an effect armed with the **same UUID** produce TWO entries | key the dictionary by `id` alone | HIGH — this is the leg that pins the (kind, id) key |
| **P4** | with **N ≥ 8** entries armed in scrambled order, `entries(now:)` is in exact `(slot, id)` order | return `Array(dict.values)` unsorted | MEDIUM-HIGH — a dictionary's per-process random order matches sorted with p ≈ 1/8! ≈ 2.5e-5, so this is a reliable red; **at N = 2 it would be a coin flip, which is why N ≥ 8 is load-bearing and not decoration** |
| **P5** | `arm` twice for one key REPLACES: `startedSecondsAgo` measures from the SECOND arm | keep-first semantics | HIGH |
| **P6** (Phase 3) | `declareOverdue(now:)` returns a slot ONCE per episode; nil on later ticks; re-armable after `disarm` | drop the latch | HIGH |

### 8.2 The item's own leg — `Tests/DAWEngineTests/AUPrepareInFlightWedgeTests.swift`

**This is the leg that distinguishes m23-av from m23-at, and it must hold the main actor
FROM INSIDE THE PREPARE WORK.** A sibling hog re-proves m23-at and proves nothing here
(ROADMAP m23-av says so explicitly). Use the `instantiator` test seam
(`AUHostRegistry.swift:234`, a `var`, already used at `Tests/DAWEngineTests/AUHostingTests.swift:158`).

Suite is deliberately NOT `@MainActor` and is `.serialized`, for the reasons
`DeadlineRaceTests` states verbatim: the reader must run off-main, and the leg starves the
main actor so it must not poison its own siblings.

Mechanics, in order (copy `DeadlineRaceTests`' `SpinWindow` mailbox — `markSpinning()`,
`markEnded(_:)`, `endInstant`):

1. `let registry = AUHostRegistry()`; track uses a component that **really exists**
   (`AUHostingTests.Self.dls` / `samp`) — the seam is only reached after
   `AVAudioUnitComponentManager` matches (`AUHostRegistry.swift:697-702`).
2. `registry.instantiator = { _, _ in window.markSpinning(); <synchronous spin for
   hogDuration>; window.markEnded(clock.now); throw CancellationError() }`. A **spin, not
   `Task.sleep`** — sleeping hands the actor back, which is the opposite of the condition
   under test.
3. Fire-and-forget the prepare: `let handle = Task { @MainActor in await registry.prepare(
   track: t, sampleRate: 48_000, timeout: budget) }`. **Do not `await` it before reading**
   — `prepare` is `@MainActor` and awaits its own chain task.
4. Spin-wait off-main on `window.isSpinning` (the handshake that stops the leg measuring
   an uncontended actor — a pass for the wrong reason).
5. **Early read (E3), taken IMMEDIATELY on observing `isSpinning`** — not at
   `spinStart + budget/2`. `startedSecondsAgo` measures from ARM (`:706`), not from spin
   start, and the arm→spin gap includes `DeadlineRace.run` entry plus the
   `Task { @MainActor in work() }` hop RE-ACQUIRING the actor `performPrepare` just
   released. Under full-suite load that gap can exceed any fixed fraction of `budget`,
   which would make a fixed-offset early read spuriously overdue. Guard it with
   `#require(entry.startedSecondsAgo < entry.deadlineSeconds)` — a slow arm→spin gap then
   fails the leg's own PRECONDITION (inconclusive) instead of its assertion (false red).
   This is `DeadlineRaceTests` leg 1's "an arming counts only if …" discipline.
6. Late read: `try await Task.sleep(for: budget + margin)`; then `let t0 = clock.now;
   let snap = registry.inFlightSnapshot(); let t1 = clock.now`.
7. Assertions, then `await handle.value` and the post-conditions.

Budget: `budget = 200 ms`, `hogDuration = 1_500 ms`. **Cost, stated because it is real:**
1.5 s of synchronous main-actor starvation inside a parallel suite whose siblings are
~78 % `@MainActor`-isolated inflates every one of them for that window — the same
second-order effect m23-at measured (17–22 s → 24.3–26.9 s). One hog, one read; do not
loop it. If the leg proves flaky under load, raise `hogDuration`, never lower the margin.

| Leg | Asserts | Kill-mutation | Confidence |
|---|---|---|---|
| **E1** | `t1 < window.endInstant!` — the off-main read COMPLETED strictly inside the spin window. **Fully relative, no wall-clock constant** (the `DeadlineRaceTests` leg-1 shape); a main-actor-gated read cannot produce it | **E1-M-a** drop `nonisolated` from `AUHostRegistry.inFlightSnapshot()` and add the mechanical `await` at the call site | MEDIUM-HIGH — the data flow is forced (the read then queues behind the spin, so `t1 > endInstant`), but the mutation **changes the signature and so requires a call-site edit**; a mutation needing a compile fix alongside it is weaker evidence than one that compiles untouched |
| **E1** (same leg) | — | **E1-M-b, the property-exact one:** wrap `AUPrepareLedger.snapshot()`'s body in `DispatchQueue.main.sync { … }`. Compiles UNTOUCHED, blocks the reading pool thread until the spin releases the actor → `t1 > endInstant` → red | HIGH for E1 itself, **but it DEADLOCKS the healthy path**: `prepareStats()` is `@MainActor` and calls `inFlightSnapshot()`, and `main.sync` from the main thread is a re-entrant serial-queue deadlock. Run this mutation `--filter`-scoped to `AUPrepareInFlightWedgeTests` only, or temporarily drop the `inFlight:` embed in `prepareStats()`. **Recorded because the deadlock is itself informative — it is the proof that the two paths genuinely differ in isolation, not a defect in the mutation.** |
| **E2** | the snapshot contains exactly one entry, `slot == "instrument"`, `id == track.id`, `overdue == true`, `deadlineSeconds == 0.2`, `component` non-nil | delete the `arm` call at `:706` | HIGH — `#require` on the entry fails on an empty array |
| **E3** | the NEGATIVE direction under real contention: an EARLY read taken the instant `window.isSpinning` is first observed reports `overdue == false`, while E2's late read reports `true` — i.e. `overdue` is not hardcoded true, and the flip happens with the main actor held throughout. **Self-validating precondition:** `#require(entry.startedSecondsAgo < entry.deadlineSeconds)` on the early read, so a slow arm→spin gap makes the leg INCONCLUSIVE on its own `#require` rather than falsely red | hardcode `overdue = true` (equivalently: compare `startedSecondsAgo > 0` instead of `> deadlineSeconds`) | MEDIUM-HIGH — direct, but P1 covers the same predicate in pure form; E3's marginal value is that it holds while the actor is genuinely held. **⚠️ CORRECTED FROM THIS DESIGN'S OWN FIRST DRAFT, and the correction is the m23-au S6 failure caught before handoff rather than after:** the draft's mutation was *"store `overdue` as a `Bool` written on the main actor at arm time"*, which under the hog leaves `overdue == false` at the LATE read — that reddens **E2**, not E3. Do not re-introduce it as an E3 row. |
| **E4** | CHARACTERIZATION of the defect, and it must be an assertion, not a comment: during the spin `registry.prepareLedger` reports overdue **while the published status has not moved** — assert after `await handle.value` that `status[track.id]` is `.failed(… "timed out" …)`, i.e. publication happened only after the spin | none (this leg pins the m23-av premise itself; it reddens if publication ever becomes non-main, which would mean route (b) landed) | MEDIUM — it is a premise pin, not a defect guard; state that in the test's own comment so a future reader does not over-trust it |
| **E5** | after `await handle.value`, `inFlightSnapshot()` is EMPTY (disarm fired) | delete the disarm in the `.timedOut` case only (`:809-811`) | HIGH — leaves exactly one leaked record |

### 8.3 Wire legs — `Tests/DAWControlTests/MainActorLivenessTests.swift` (extend)

Pure, static, fake snapshot + fake `inFlight` array. No sockets, no wall time.

| Leg | Asserts | Kill-mutation | Confidence |
|---|---|---|---|
| **W1** | wedged snapshot + `engine.auPrepareStats` request → `.success` carrying `mainActor.responsive == false`, `mainActor.wedgedForSeconds`, and the `inFlight` array verbatim — **not** the teaching error | remove the `engine.auPrepareStats` branch | HIGH |
| **W2** | the wedged payload has **no** `instrumentPrepares` / `tracks` / `effects` keys | emit `"instrumentPrepares": 0` | HIGH — key-absence assertion |
| **W3** | a wedged request for some OTHER verb (`transport.play`) still gets the teaching error | replace the two-verb branch with "answer everything" | HIGH |
| **W4** | a RESPONSIVE snapshot returns `nil` for `engine.auPrepareStats` (normal route) | drop `guard !snapshot.responsive` | HIGH — likely already covered by an existing leg at `:171-173` |
| **W5** | the healthy handler response carries `mainActor: {responsive: true}` alongside the counters | delete the echo in `Commands.swift` | HIGH — mirrors the existing watchdog test |
| **W6** | with a **nil** in-flight provider and a wedged snapshot, the response OMITS the `inFlight` key entirely — it does NOT say `inFlight: []` | emit `inFlight: []` when the provider is nil | HIGH — key-absence assertion, and it pins §7 step 5's honesty rule |

### 8.4 What the gate does NOT cover, stated so nobody over-reads it

- **No test exercises a REAL third-party plug-in wedging the main actor.** Surge XT cannot
  be driven headlessly here (see [[daw-pro-au-hosting-wedge]]); the `instantiator` seam
  reproduces the ISOLATION SHAPE (work synchronously holding the actor) faithfully, which
  is the property under test, but it is a simulation of the mechanism, not of the vendor.
- **The mach-uptime-vs-wall-clock choice is not gated.** A mutation to `Date()` would pass
  every leg above; it is caught by review and by the clock-injection convention only. A
  test would need a system sleep. Filed as a known limit, not hidden.
- **No leg discriminates derive-at-read from Alternative B** (writing the verdict off-main
  from the deadline task). The two produce IDENTICAL observable behaviour — `false` early,
  `true` late — so no black-box test can separate them. The choice rests entirely on the
  one-home argument in §3-B (two publishers of one outcome), which is a REVIEW property,
  not a gated one. **Say so; do not let §8 imply otherwise.** An earlier draft of E3
  claimed to gate it and was wrong.
- **Nothing here proves the app RECOVERS.** It cannot; see §10.

---

## 9. FAILURE MODES

1. **A leaked record.** If a disarm site is ever missed, a slot reports overdue forever.
   Mitigation: exactly one arm and one disarm site per kind, both inside `performPrepare`/
   `performPrepareEffect`, paired in the same function; E5 pins the timeout case. Blast
   radius is one stale diagnostics row — it never touches audio or the graph.
2. **Lock contention.** `snapshot()` takes an `NSLock` held only for a dictionary copy of
   at most (tracks + effects) entries. Held by the main actor only for arm/disarm (two
   dictionary writes). It is not reachable from the render thread (§4.4). A `MainActor`
   arm can never block on a long critical section because no critical section is long.
3. **`arm` colliding with a leaked record for the same key.** `arm` replaces (Phase 1.2).
   The older, leaked record is lost. Accepted: chains make it unreachable, and the
   alternative (keep-oldest) would let one leak permanently mask every later prepare.
4. **`overdue` reported on a responsive machine.** Real and expected — the m23-at
   second-order regime. This is why the payload carries `mainActor` and why §4.3 forbids
   concluding "wedged" from `overdue`. In a test process the 60 s
   `testPrepareTimeout` keeps it quiet.
5. **The wedged payload's shape misread as the full one.** Mitigated by the always-present
   `mainActor` discriminator (§5.1/§5.2) and W2.
6. **Someone later "fixes" `arm`'s replace semantics to match `MainActorLiveness`.**
   Mitigated by P5 plus the doc comment that states the divergence and its reason.
7. **The E1 leg silently degrading to the m23-at sibling-hog case.** If a future refactor
   moves the spin out of `instantiator`, E1 still passes and stops testing this item.
   Mitigated by E4 (the premise pin) and by an explicit comment; a source-site pin on
   "the spin is inside the instantiator closure" is possible but was judged not worth a
   pinned-string test.

---

## 10. WHAT THIS DOES **NOT** ACHIEVE (close-out wording)

Use these sentences; they are what the tick must not be readable as saying.

> **m23-av does not fix the Surge XT wedge, and this tick must not be read as saying so.**
> You cannot preempt a thread that is synchronously executing someone else's code, and
> nothing in this item tries to. m23-at made the AU-prepare deadline DECIDE on wall time;
> m23-av makes that decision **OBSERVABLE while the main actor is still held**, and
> nothing more. During a wedge the UI is still frozen, every other control command still
> returns the teaching error, the plug-in still holds the main thread for as long as it
> holds it, and the eventual publication of `status[id] = .failed("… timed out …")` still
> waits for the actor. The app does not recover faster by one millisecond.
>
> What changes: `engine.auPrepareStats` now answers DURING the wedge with which slot,
> which component, how long it has been in flight, and whether its deadline has passed —
> instead of a bare *"main actor unresponsive for N s"* and a silence about the cause. An
> agent or a user can name the plug-in that is doing it while it is doing it.
>
> This is the m18-b doctrine — **DETECTION AND HONESTY ONLY: no auto-kill, no auto-restart**
> — and it is **the honest ceiling for in-process AU hosting**. The actual fix is
> out-of-process AUv3 hosting (route (b)): a separate item, a milestone rather than a
> cycle, requiring full Xcode, an app bundle, and hosting entitlements. It is not started
> here and no part of this design is a step toward it beyond making the case for it
> measurable.
>
> Also unchanged, and worth stating because it is the reassuring half: the render thread
> runs straight through a main-actor wedge. Audio already playing keeps playing.

---

## 11. `docs/ARCHITECTURE.md` — "Key future decisions": ENTRY ALREADY ADDED

Added 2026-08-03 as the first entry of the section (`docs/ARCHITECTURE.md:173`), marked
**SETTLED BY DESIGN … implementation pending** on the `m16-h` / Copilot-persistence precedent.
The implementing agent flips it to SHIPPED at close-out. Substance, restated here so this doc
is self-contained:

> - **AU-host prepare observability during a main-actor wedge: SETTLED BY DESIGN (m23-av,
>   2026-08-03; design `docs/research/design-m23av-prepare-status-offmain.md`;
>   implementation pending).** In-process AU hosting's honest ceiling is DETECTION, not
>   preemption. m23-at made the prepare deadline decide on wall time (`DAWCore.DeadlineRace`);
>   m23-av makes that decision READABLE while the actor is still held, by giving
>   `AUHostRegistry` a `nonisolated`, lock-protected in-flight ledger (arm where `.pending`
>   is written, disarm in the outcome switch, `overdue` DERIVED at read time from injected
>   mach uptime) and by widening `ControlServer.wedgeIntercept`'s allow-list to
>   `engine.auPrepareStats`. **One home:** the ledger stores EVIDENCE (armed-at, deadline)
>   and computes the VERDICT on demand; published `status` stays main-actor-owned and is
>   never mirrored. **Rejected: migrating `status`/`attempted`/the counters off-main**
>   ("Shape S") — its premise (that the wedged payload must be a complete
>   `EngineAUPrepareStats`) is refuted by the `engine.watchdogStatus` intercept, which
>   hand-builds a partial object, and it would have forced `knownTrackIDs` to drop its
>   `instruments.keys` term, trading an AU-lifecycle GC invariant for a fuller diagnostics
>   payload; **rejected: `DeadlineRace.run(onTimeout:)` writing the verdict off-main** — two
>   publishers of one outcome, and it reopens the primitive m23-au consolidated; **rejected:
>   a new bare verb** — additive fields on `engine.auPrepareStats` keep one discoverable
>   surface (the m18-b `mainActor` precedent). **NOT settled here: out-of-process AUv3
>   hosting**, which is the only thing that actually prevents a third-party plug-in from
>   blocking our main thread — a milestone, needing full Xcode + entitlements.

---

## 12. COMPILER PROBES — RUN, NOT ASSUMED

`swiftc -typecheck -swift-version 6 -strict-concurrency=complete`, Swift 6.x on this
machine, 2026-08-03. Probe source:
`/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/73c8163a-27b5-48fc-94b9-8e63836c64d7/scratchpad/probe1.swift`.

**Second run: exit 0, ZERO diagnostics.** All of the following compile:

- **A** — a `nonisolated func` on a `@MainActor final class` reading a `nonisolated let`
  lock-protected store and returning a `Sendable` snapshot.
- **B** — a `@MainActor` computed accessor over that same store (the "one storage, two
  views" shape, had Shape S been chosen).
- **C** — a `nonisolated` method on `@MainActor Engine` reaching a **plain `let reg`** of
  `@MainActor Registry` type and calling a `nonisolated` method on it. **This is why
  `AudioEngine.auRegistry` needs no declaration change.**
- **D** — a `@MainActor protocol` carrying a `nonisolated` requirement.
- **E** — a default implementation of that nonisolated requirement in a protocol
  extension. (Not needed by the chosen shape; recorded because it removes the only reason
  to avoid touching `AudioEngineProtocol` later.)
- **F** — an escaping `@Sendable` closure capturing a `@MainActor` class and calling its
  `nonisolated` method — the `DAWProApp` provider-wiring shape. (A global-actor-isolated
  class is implicitly `Sendable`; the m23-au Correction 1.)
- **G** — a plain `nonisolated` free function reading `engine.reg.store` through BOTH a
  plain `let` and a `nonisolated let`.

**P1 — the ONE thing that errored, and it changes an implementation detail:**

```
error: main actor-isolated default value in a nonisolated context
    nonisolated let reg2 = Registry()
```

A `nonisolated` stored property may not take a default value produced by a `@MainActor`
initialiser. Consequence for Phase 1.3: `AUPrepareLedger`'s `init` must be nonisolated
(it will be — it is a plain `final class`, not `@MainActor`), OR the property must be
assigned inside `AUHostRegistry.init`. Assigning in `init` compiled cleanly. **Flag for
the implementer: if the ledger is ever moved into a `@MainActor` type, this error is what
you will see, and the fix is the initialiser, not `@unchecked`.**

---

## 13. FULL XCODE / ENTITLEMENTS — WHAT IS AND IS NOT GATED

- **Nothing in m23-av route (a) needs full Xcode.** It is Swift Package code across
  DAWCore / DAWEngine / DAWControl / DAWApp, buildable with `swift build` and testable
  with `./scripts/test.sh`.
- **Route (b) does, and this is the explicit flag the constitution asks for:**
  out-of-process AUv3 hosting needs an app bundle, code signing, and the
  `com.apple.security.temporary-exception` / AU host entitlements — i.e. full Xcode
  (`xcodebuild -version` check first) and, for distribution, the Apple Developer
  enrolment that already blocks pkg-b/c/e. Do not start it inside a cycle.
- `dist/DAWPro.app` is NOT rebuilt by this item. Like m23-at and m23-au, the fix will exist
  only in the tree until the user authorises `scripts/bundle.sh`.

---

## 14. WHAT I COULD NOT ESTABLISH

1. **No kill-mutation was applied.** Design-only cycle. §8 is a set of claims with
   confidences, not observations. The E1 row in particular is flagged MEDIUM-HIGH because
   its mutation requires a call-site compile fix.
2. **The real Surge XT path was not exercised.** [[daw-pro-au-hosting-wedge]] is the
   evidence for "minutes"; I did not reproduce it (doing so wedges the machine's main
   actor for minutes, and the memory rule says prefer GM banks). The `instantiator` seam
   reproduces the shape, not the vendor.
3. **`AVAudioUnitComponentManager.components(matching:)` at `AUHostRegistry.swift:697`
   runs on the main actor BEFORE the race and is not inside any deadline.** A component
   manager that itself stalls (a corrupt plug-in cache; a slow `auval` scan) would wedge
   the main actor with NO in-flight record armed, and m23-av would report nothing. I did
   not measure whether that call can stall in practice. **This is a real residual hole and
   it should be filed as its own item rather than papered over here** — arming before the
   lookup is the wrong fix (it would spray phantom records on every `.missing` path, §7
   Phase 1.3).
4. **Whether Phase 3's breadcrumb is wanted at all** is a product call I made on the
   item's own words ("the control port **and the watchdog** could report"). It is
   separable precisely so it can be dropped.
5. **Nothing left un-measured about the `Codable` change — I checked it rather than
   flagging it.** Findings, all verified:
   - Six in-tree constructors (`Model.swift:2541`, `AUHostRegistry.swift:164`, four in
     `Tests/DAWControlTests/EngineAUPrepareStatsCommandTests.swift`); a defaulted
     `inFlight: [InFlightEntry] = []` init parameter covers all six.
   - **`scripts/gates/m20e-flip-path.mjs` is SAFE.** Its `countersEqual` (`:661-666`)
     compares the four scalar counters FIELD BY FIELD and carries an explicit comment
     forbidding `JSON.stringify` equality (m23-br-2 observed key-order instability). There
     is no `Object.keys` / `deepStrictEqual` / exact-key-set assertion anywhere in the
     file. Adding `inFlight` cannot break its `settleCounters` loop or any leg.
   - **`EngineAUPrepareStatsCommandTests.swift:105` DOES hold an exact key-set assertion —
     `#expect(track.objectValue?.keys.sorted() == ["trackId"])` — but it is on a
     `TrackEntry`, not on the top-level object.** Adding `inFlight` and `mainActor` at the
     TOP level does not touch it. **Trap for a later author: adding any optional field to
     `TrackEntry` or `EffectEntry` WILL redden that leg.**

6. **`EngineAUPrepareStats` is `Equatable`, and `inFlight` makes it time-varying.** After
   this change, `==` between two reads of a registry with a prepare in flight is
   guaranteed false rather than merely likely false. The one in-tree use is
   `Tests/DAWEngineTests/AUPrepareStatsTests.swift:47` —
   `#expect(registry.prepareStats() == EngineAUPrepareStats.idle)` — which stays green
   because a fresh registry's ledger is empty, and which would go red (CORRECTLY) if
   anything ever armed at construction. No other equality comparison exists. Anyone
   tempted to add one should compare counters, not the struct.
