# Design — Hosted AU Parameter Surface (`au.describeParams` / `au.setParam`)

**Status**: design only, not implemented. **Date**: 2026-07-20.
**Goal**: read and set the `AUParameterTree` of hosted Audio Unit instruments and effects over the
control WebSocket and MCP, so agents can turn plugin knobs without the vendor window.

## 1. Verified current state (grep/read, 2026-07-20)

- `Sources/**` has **zero** `parameterTree`/`AUParameter*` usage. Tests already prove the surface
  exists: `Tests/DAWEngineTests/AUEffectHostingTests.swift:59-61,124,167,184` reads
  `hosted.auAudioUnit.parameterTree?.allParameters` on live AUDelay/AULowpass instances.
- AU hosting: `AUHostRegistry` (`@MainActor`, `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift`)
  owns `HostedAUInstrument` (keyed by trackID) and `HostedAUEffect` (keyed by **effectID alone**).
  `auAudioUnit` is a documented MAIN-ACTOR-ONLY member; the render thread touches only blocks
  captured at init. `AudioEngine.hostedInstrumentAudioUnit(forTrack:)` /
  `hostedEffectAudioUnit(forEffect:)` (AudioEngine.swift:1354-1363) are the concrete-class-only
  AU leaks used by the plugin-window layer.
- Engine seam: `AudioEngineControlling` (`Sources/DAWCore/EngineProtocol.swift:171`, `@MainActor`),
  Foundation-only DTOs (`AudioUnitComponentInfo` precedent), additive methods with no-op defaults
  (`audioUnitEffectStatus` precedent, line 547). `ProjectStore` forwards; DAWControl stays
  engine-free (`instrument.listAudioUnits` comment, Commands.swift:786-788).
- Master chain is **built-in only** (design-m13d D4a): `addMasterEffect` throws
  `masterChainBuiltInOnly` for `.audioUnit` (ProjectStore.swift:1381). So this surface needs **no
  "master" sentinel** — hosted AUs exist only as track inserts and track instruments.
- Target-validation precedent: `requirePluginTarget` (Commands.swift:3891) — trackId + optional
  effectId, kind checks with teaching errors (built-in kinds rejected; `.soundBank` gets a
  dedicated redirect error).
- `withObjCExceptionBarrier` (Sources/DAWEngine/ObjCExceptionBarrier.swift) is the C8 rule:
  vendor ObjC raises at control-plane entry points convert to `EngineError.engineException`.
- Counts before this feature: 139 wire commands, 142 MCP tools. Additive-only law applies.

## 2. Decisions at a glance

| Question | Decision |
|---|---|
| Command family | **Unified `au.*` pair** (`au.describeParams`, `au.setParam`), not fx./instrument. splits |
| Addressing | trackId (required) + effectId? (omit ⇒ the track's AU instrument) — the `plugin.openUI` target model, reusing its validation |
| Param address | `AUParameterAddress` (UInt64) as **decimal string** in all JSON (2^53 double hazard); set accepts string (canonical) or exact integer number |
| Huge trees | Paging: `offset` (default 0) + `maxParams` (default 512, clamp 1…4096), `totalCount` + honest `truncated` flag |
| Empty/opaque trees | Success, never an error: `hasParameterTree:false` (nil tree) or `totalCount:0` — plus teaching text on set |
| Out-of-range set | **Silent clamp** to [min,max] (fx.setParam / track.setVolume precedent), echo the AU's read-back value |
| Get-one | No third command: `au.describeParams` takes an `addresses` filter |
| Observation | v1 = poll-on-describe; observer tokens are follow-up work |
| Undo | v1 = **no undo step** (parity with edits made in the vendor window via plugin.openUI); save-time `fullStateForDocument` capture persists the values |

**Why unified `au.*`, not `fx.describeAUParams` + `instrument.describeAUParams`:** the split would
duplicate paging, truncation, address parsing, and the error taxonomy across four commands and four
MCP tools with zero expressive gain. The established idiom for "the hosted AU behind a track slot"
is already unified: `plugin.openUI/closeUI` address both flavors with trackId + optional effectId
and one validator (`requirePluginTarget`). `fx.describe` would also be a false neighbor — it
describes built-in effect **kinds** (schemas), while this surface describes one live **instance**;
overloading the fx. prefix invites that confusion. A new `au.` prefix is cleanly additive.

## 3. Engine API (DAWCore seam + DAWEngine impl)

New Foundation-only types in `Sources/DAWCore/EngineProtocol.swift` (Sendable, Equatable, Codable):

```swift
public enum HostedAUTarget: Sendable, Equatable {
    case instrument(trackID: UUID)
    case effect(effectID: UUID)      // registry keys effects by effectID alone
}

public struct HostedAUParameterInfo: ... {
    public var address: String        // UInt64.description — JSON-safe
    public var identifier: String     // AUParameter.identifier
    public var displayName: String
    public var keyPath: String        // "group.param" — flat v1 nod to hierarchy
    public var unit: String           // AudioUnitParameterUnit mapped to a label
                                      // ("seconds", "hertz", "decibels", …, "unknown(n)")
    public var unitName: String?      // vendor string, customUnit only
    public var minValue: Double
    public var maxValue: Double
    public var value: Double          // current, read at describe time
    public var writable: Bool         // flags.contains(.flag_IsWritable)
    public var readable: Bool
    public var valueStrings: [String]?  // indexed params only (nil otherwise)
}

public struct HostedAUParameterPage: ... {
    public var hasParameterTree: Bool // false ⇔ AU publishes nil tree (opaque state)
    public var totalCount: Int        // full tree size, pre-paging
    public var offset: Int
    public var truncated: Bool        // offset + parameters.count < totalCount
    public var parameters: [HostedAUParameterInfo]
    public var unknownAddresses: [String]  // addresses-filter misses; empty otherwise
}

public enum HostedAUParameterError: Error, Sendable, Equatable {
    case noHostedAU                   // no .ready instance for the target
    case noParameterTree
    case unknownAddress(String)
    case notWritable(String)
    case invalidAddress(String)       // not a UInt64 decimal
    case nonFiniteValue
}
```

Protocol additions (`AudioEngineControlling`, additive with defaults so fakes compile unchanged —
default `describe` returns nil, default `set` throws `.noHostedAU`):

```swift
func describeHostedAUParameters(_ target: HostedAUTarget, offset: Int, maxParams: Int,
                                addresses: [String]?) throws -> HostedAUParameterPage?
@discardableResult
func setHostedAUParameter(_ target: HostedAUTarget, address: String,
                          value: Double) throws -> HostedAUParameterInfo
```

`AudioEngine` implementation notes:
- Resolve the AU via the existing registry accessors (`preparedInstrument`/`preparedEffect`);
  nil ⇒ return nil / throw `.noHostedAU` (the store adds pending/missing/failed detail from
  `audioUnitStatus`/`audioUnitEffectStatus` — the plugin-window open-failure precedent).
- Wrap the tree walk and the set in `withObjCExceptionBarrier("AU parameter read"/"write")` —
  the ObjC property surface of a v2 bridge can raise inside vendor code (C8 rule).
- Enumeration = `parameterTree?.allParameters` (flat; the tree's own order, stable per instance),
  slice `[offset, offset+maxParams)`. `allParameters` materializes the whole array even when
  paging — accepted v1 cost (a few ms for thousand-param synths, control plane only).
- Set = parse address (`UInt64(string)` else `.invalidAddress`), look up via
  `parameterTree?.parameter(withAddress:)` (else `.unknownAddress`), reject non-finite values,
  check `.flag_IsWritable` (else `.notWritable`), clamp host-side to [minValue, maxValue], write
  `parameter.value = clamped` (Apple contract: safe from any thread, marshalled to the AU without
  blocking the render thread), then **read back** `parameter.value` into the returned info — some
  AUs quantize/step, and the echo must be the truth.
- No `dlsBankQueue` hop: the m18-d/m19-j law covers LoadInstrument/initialize/dispose, not
  parameter access. (Sound-bank tracks are rejected at the store layer anyway — below.)
- No model mutation, no `tracksDidChange`: an AU param write is live engine-side state, captured
  into `stateData` at save time via the existing `instrumentState`/`effectState` path.

`ProjectStore` forwarders (`describeAudioUnitParams` / `setAudioUnitParam`, trackId + effectId?):
validate the pair like `requirePluginTarget` does (track exists; effect exists **on that track**
and `kind == .audioUnit`; instrument track with instrument kind `.audioUnit` — `.soundBank` throws
the redirect teaching error since `SoundBankConfig` is the single source of truth (LAW L3) and
AUSampler tree edits would be silently lost on save), then call the engine with the resolved
`HostedAUTarget`, mapping nil/`.noHostedAU` to a status-naming teaching error.

## 4. Wire commands (additive; Commands.swift name list + handlers + docs/ARCHITECTURE.md table)

### `au.describeParams` (139 → 140)

params: `trackId` (required UUID — no "master": the master chain cannot host AUs, D4a),
`effectId?` (UUID — omit for the track's AU instrument), `offset?` (int ≥ 0, default 0),
`maxParams?` (int 1…4096, default 512), `addresses?` (array of address strings — exact-get
filter; **mutually exclusive** with offset/maxParams, rejected with a teaching error).

Response (`HostedAUParameterPage` + target echo):

```json
{ "trackId": "…", "effectId": "…",
  "componentName": "AUDelay",
  "hasParameterTree": true, "totalCount": 1863, "offset": 0,
  "truncated": true,
  "parameters": [ { "address": "281474976710659", "identifier": "delayTime",
      "displayName": "Delay Time", "keyPath": "delayTime", "unit": "seconds",
      "unitName": null, "minValue": 0.0, "maxValue": 2.0, "value": 1.0,
      "writable": true, "readable": true, "valueStrings": null } ],
  "unknownAddresses": [] }
```

An AU with opaque state answers `hasParameterTree:false, totalCount:0, parameters:[]` —
**success, never an error** (Kontakt-style units are healthy hosts that simply don't publish).

### `au.setParam` (140 → 141)

params: `trackId` (required), `effectId?` (omit ⇒ instrument), `address` (required — decimal
string, canonical; an exactly-integral JSON number ≤ 2^53 is tolerated), `value` (required finite
number; out-of-range **clamps silently**, fx.setParam precedent).

Response: `{ "trackId", "effectId"?, "parameter": { …refreshed HostedAUParameterInfo… } }` —
`parameter.value` is the post-set read-back, so quantizing AUs answer honestly.

### Error taxonomy (both commands, LocalizedError-mapped teaching messages)

| Condition | Error |
|---|---|
| unknown track / effect not on track | `trackNotFound` / `effectNotFound` (store precedent) |
| built-in effect kind / built-in instrument | "…is a built-in \<kind\> — AU parameters apply only to Audio Unit effects/instruments" (requirePluginTarget wording) |
| `.soundBank` instrument | redirect to `instrument.listSoundBankPrograms` + `track.setInstrument` (plugin.openUI wording; LAW L3) |
| AU pending / missing / failed | names the status + failure reason (plugin-window open-failure precedent) |
| `trackId:"master"` | "the master chain hosts built-in effects only — AU parameters apply to track inserts" |
| set on nil/empty tree | "publishes no parameter tree (opaque state) — use plugin.openUI to edit it visually" |
| malformed address | "'address' must be the decimal string form of the parameter address (see au.describeParams)" |
| unknown address | `unknown AU parameter address '…' — call au.describeParams to list addresses` |
| read-only param | "parameter '…' is not writable" |
| NaN / infinite value | "'value' must be a finite number" |
| out-of-range value | **not an error** — silent clamp |
| unknown addresses in describe filter | **not an error** — reported in `unknownAddresses` |

## 5. MCP tools (142 → 144, `mcp-server/src/server.ts`)

- `au_describe_params` — read-only ⇒ `server.registerTool` directly (fx_describe precedent).
  zod: `trackId: z.string().min(1)`, `effectId/offset/maxParams/addresses` optional. Description
  teaches: workflow (describe → set), addresses are opaque per-instance strings (never guess or
  reuse across instances), paging via `truncated`/`offset`, and that `hasParameterTree:false`
  means "edit via plugin_open_ui instead".
- `au_set_param` — mutating ⇒ the strict `registerTool` wrapper. zod: `trackId`, optional
  `effectId`, `address: z.string().min(1)`, `value: z.number()`. Description states the clamp
  contract and that the response echoes the AU's actual resulting value.

Both bridge 1:1 to the wire commands (`bridge.send("au.describeParams", …)`). Parity checks
(command list ↔ tool catalog) and the Explain catalog pick up the two new names.

## 6. Concurrency plan

- **Ownership**: `AUHostRegistry` (@MainActor) owns the wrappers; `auAudioUnit` stays
  MAIN-ACTOR-ONLY per the existing contract. The whole path — WebSocket handler → ProjectStore →
  AudioEngine → registry → `parameterTree` — runs on the main actor; the render thread is never
  involved (parameter delivery to the DSP side is the AU's own RT-safe mechanism).
- **Raises**: every tree touch sits inside `withObjCExceptionBarrier` (vendor ObjC can raise;
  unwinding through a MainActor job frame is the proven m16-a poison).
- **Invalidation**: no retained tree references — each command resolves the AU fresh from the
  registry, so release/re-prepare races collapse to `.noHostedAU`/status errors. Nothing new to
  hook on `hostedAUReleased`.
- **Observation**: v1 deliberately skips `token(byAddingParameterObserver:)` / KVO. Values move
  under us (vendor window, future automation) — describe re-reads on every call, which is the
  honest poll contract. Live push (an `au.paramChanged` notice + observer token lifecycle tied to
  `hostedAUReleased`) is follow-up work.

## 7. Test plan

Headless (`./scripts/test.sh` — never bare `swift test`):
- **DAWEngineTests** (real system AUs, AUEffectHostingTests harness): AUDelay (`aufx dely appl`)
  already proves an enumerable tree with a seconds-unit param — assert describe returns
  `hasParameterTree:true`, totalCount > 0, a seconds param with decimal-string address; set the
  delay time by address, assert read-back moved, then re-run the impulse render and assert the
  echo peak moved accordingly (audible truth, not just API truth). AULowpass (`lpas`) covers the
  hertz param + set-then-describe round-trip. Instrument flavor: DLSMusicDevice (`aumu dls appl`)
  hosted via `.audioUnit` — print `[measured]` tree size, tolerate small trees (never assume
  counts; the suite's stance). Paging: `maxParams:1` walks AUDelay's tree with stable order,
  `truncated` honest at every step; addresses filter hits + reports misses.
- **DAWControlTests** (fake engine, AudioUnitControlTests precedent): full error taxonomy of §4
  (built-in kinds, soundBank redirect, master rejection, pending/missing/failed naming, unknown
  address, non-writable, NaN), wire shapes for truncated and `hasParameterTree:false` pages
  (fakes make the opaque-tree case deterministic — no system AU guarantees an empty tree),
  clamp-and-echo on set, rejectUnknownKeys.
- **mcp-server npm tests**: tool registration/parity counts, zod strictness of `au_set_param`.
- **Staging app (port 17695 ONLY — never 17600)**: live gate — `fx.add` an AUDelay, describe and
  set over the real wire during playback (no glitch), `plugin.openUI` to eyeball the moved knob;
  if a big third-party synth (e.g. Surge XT) is installed, verify the 512 default cap + paging on
  a thousands-deep tree. `mcp-verify` skill for the MCP round trip.

## 8. v1 scope cut — explicit deferrals

1. **Automation-lane binding of AU params** (lane target = trackId/effectId/address; needs
   sample-accurate scheduling via `scheduleParameterBlock`/ramping — its own RT design).
2. **Live observation / change push** (observer tokens, `au.paramChanged` notices, UI meters).
3. **Preset management** (`factoryPresets`, user presets, `fullState` snapshots as commands).
4. **Display-value strings** (`string(fromValue:)` read, `value(fromString:)` writes).
5. **Group hierarchy** beyond the flat `keyPath` hint.
6. **Undo integration** for AU param edits (today: vendor-window parity — no undo step; the
   values persist via save-time state capture).
7. **Master-chain AU params** — blocked on the master chain hosting AUs at all (D4a).

## 9. Implementation touch points

| File | Change |
|---|---|
| `Sources/DAWCore/EngineProtocol.swift` | DTOs, `HostedAUTarget`, `HostedAUParameterError`, 2 protocol methods + defaults |
| `Sources/DAWEngine/AudioEngine.swift` | implement both methods over the registry, barrier-wrapped |
| `Sources/DAWCore/ProjectStore.swift` | `describeAudioUnitParams` / `setAudioUnitParam` with target validation + status-naming errors |
| `Sources/DAWControl/Commands.swift` | 2 names in the command list + handlers (share/extract the `requirePluginTarget` kind checks) |
| `mcp-server/src/server.ts` | `au_describe_params`, `au_set_param` |
| `Tests/DAWEngineTests`, `Tests/DAWControlTests`, mcp-server tests | per §7 |
| `docs/ARCHITECTURE.md`, CHANGELOG, roadmap tick | close-out convention |
