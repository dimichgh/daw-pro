# m13-d Design Note — Master Insert Chain

**Author**: daw-architect · 2026-07-12
**Status**: SETTLED — GO-WITH-CONDITIONS (C0 bit-transparency spike is condition zero; fail = fallback topology, double-fail = STOP and report)
**Scope**: design only; implementation split d-1 (audio-dsp-engineer) / d-2 (swift-app-engineer + MCP bits)

> **C0 OUTCOME UPDATE (d-1, 2026-07-12): D1 FAILED bit-transparency; the SHIPPED topology
> is the §1-B fallback.** The mechanism (localized to a single ulp in the C0 A/B):
> `AVAudioMixerNode` applies `outputVolume` per input DURING accumulation (`a·v + b·v + …`),
> while D1's masterSumMixer sums at unity and scales once (`(a+b+…)·v`) — first diff at
> frame 241, `0x3f172767` vs `0x3f172768`, under any non-unity master fader. Production
> shape: permanent post-fader insert `mainMixerNode → masterChainHost → outputNode`
> (`ensureMasterSandwich()`, attach-only, never sets `needsEngineRebuild` — pinned);
> master fader stays on `mainMixerNode.outputVolume` (now PRE-chain); meter tap +
> masterAnalyzer HONESTLY RELOCATED to the chain host's output (§1-B's stated condition);
> metronome/test-tone now pass THROUGH the chain (documented tradeoff, inverts the §1 D1
> policy). All §8 gates passed under §1-B: C1 anchors byte-identical (agent + orchestrator
> independently), C2 ceiling −10.000000058 dBTP, C3 residuals 0.0, C7 240/480-sample PDC.
> Read §1's D1 arguments as HISTORY; §1-B + this update is the as-built record. d-2 must
> present the master chain as post-fader in any user-facing copy that mentions signal flow.
**Baselines designed against**: Swift 2066/239, npm 86/86, wire 119 / MCP 122, Copilot catalog 47, Explain 65. The m12-b anchors (mix `b4c56164…`, window `a14f4615…`, stems `3a8d0acd…`/`c1f19943…`/`e523d958…`) are the permanent null-case oracle.

---

## 0. The problem in one paragraph

VISION's "master this for streaming loudness" is unreachable: there is no master insert
chain (audit-m13.md F4, line 18; MixerStripView.swift:352-355 documents the absence in
the master strip's own doc comment), `render.bounce lufsTarget` is static gain only, and
the PDC report already reserves the slot — `masterChainLatencySamples` exists as an init
parameter defaulted/hardwired to 0 (LatencyCompensation.swift:316-324, fed the literal
`0` at PlaybackGraph.swift:1018, with the header comment at PlaybackGraph.swift:941-944
explicitly promising "a future master chain feeds `masterChainLatencySamples` in the
report only"). Two later rounds changed the constraints this must be designed under:
**m13-a** made ANY announce-class topology change on a once-rendered engine a
whole-engine discard-and-rebuild (PlaybackGraph.swift:507-513: `announceRoutingMutation`
sets `needsEngineRebuild`; ~33–143 ms rebuild — an audible gap), and **m13-c** made
announce-capability the recording-guard criterion. Both are load-bearing below.

---

## 1. Graph topology — the announce trap

**DECISION D1: ALWAYS-INSTALLED master sandwich.** Every `PlaybackGraph` — live, post-
rebuild, and offline — unconditionally builds, once per graph lifetime and before the
first render:

```
track/bus strip mixers ──► masterSumMixer ──► masterChainHost ──► engine.mainMixerNode ──► outputNode
                           (unity, no tap)    (ChainHostAU)        (master fader + meter tap
                                                                    + masterAnalyzer, implicit → output)
```

This is the proven strip sandwich shape verbatim (`sumMixer → chainHost → mixer`,
PlaybackGraph.swift:1265-1312 `makeStripSandwich`) transplanted to the master position:

- **Chain edits are never topology.** ChainHostAU's contract: "Chain edits are atomic
  snapshot publishes into the processor — the node itself is PERMANENT per strip and
  graph topology never moves for a chain edit" (ChainHostAU.swift:18-20). A master
  `fx.add` mid-play is a chain publish, exactly like a track `fx.add` — no announce, no
  rebuild, zero transport interruption. This is what satisfies the roadmap's live-add
  gate BY CONSTRUCTION.
- **Inserts sit PRE-fader**, matching every strip (chainHost feeds the fader mixer) and
  the Logic stereo-out convention. `masterVolume` stays where it is today — ONLY on
  `mainMixerNode.outputVolume` (AudioEngine.swift:350, :898; OfflineRenderer.swift:207;
  those sites do not change). `masterSumMixer` parameters are NEVER touched (the
  sumMixer rule, PlaybackGraph.swift:1266-1268) — no double-application of the fader is
  possible.
- **Master meter/analysis stay honest for free.** The master meter tap
  (AudioEngine.swift:334-335) and `masterAnalyzer` live on `mainMixerNode`, which is now
  DOWNSTREAM of the chain — the meters and `mixer.masterAnalysis` show the limiter's
  output, and the documented "measured POST-master-fader (what you hear is what is
  analyzed)" contract (EngineProtocol.swift:315-316) is preserved verbatim.
- **Metronome and test tone bypass the chain** (policy, v1): both connect directly to
  `mainMixerNode` today (Metronome.swift:68, AudioEngine.swift:1618) and KEEP those
  connections — the click never pumps the master limiter, and two connect sites stay
  untouched. Documented as deliberate; revisit only if a user asks for click-through-
  master.
- **Sidechain key bus stays dark.** The master ChainHostAU declares bus 1 like every
  instance (static bus counts, ChainHostAU.swift:163-166) but `setKeyConnected` is never
  called for it — the flag stays 0 and the render block never touches bus 1
  (ChainHostAU.swift:258-259). §4 rejects master sidechain at the store, so no key edge
  can ever target it.
- **Telemetry**: `setPerformanceContext` at node creation, before first render — the
  boundary contract (ChainHostAU.swift:363-373). Master chain DSP is counted by perf-b
  like any strip.

**Rejected alternative A — lazy install on first master fx.add.** Installing the node
mid-life is a topology change; on a once-rendered engine that is announce-class →
`needsEngineRebuild` → whole-engine discard and cold rebuild (m13-a, ROADMAP.md:214),
which is a measured 33–143 ms audio gap. That flatly violates the roadmap gate "live add
EQ+limiter on master mid-play, zero transport interruption" (ROADMAP.md:217). Dead on
arrival post-m13-a.

**Rejected alternative B — post-fader insert (`mainMixerNode → chainHost →
outputNode`).** Smaller null-path delta (strip sum untouched), but: (i) the chain lands
POST-fader, breaking the inserts-then-fader convention every strip follows; (ii) the
master meter tap and masterAnalyzer on `mainMixerNode` would read PRE-chain — the meters
would not show the limiter working, violating the "what you hear is what is analyzed"
contract and honest-metering precedent; relocating the tap to `outputNode` is its own
risk surface. B survives only as the C0 FALLBACK (with the tap relocation done
honestly) if D1 fails bit-transparency.

### 1.1 The null-case burden and construction rules

With D1, the empty master chain is in the anchor path — so the m12-b byte oracle
REQUIRES the sandwich to be bit-transparent. Evidence it should be: an empty
ChainHostAU is "pull-through: zero added latency, no copy" (ChainHostAU.swift:16-18) and
every anchor was ALREADY rendered through per-strip instances of exactly this node; the
new float math is confined to moving the N-input sum from `mainMixerNode` into
`masterSumMixer` (same `AVAudioMixerNode` DSP, deterministic bus-index sum order,
unity), leaving `mainMixerNode` a single-input fader stage — `sum(strips) ×
masterVolume` in the same order as today. Plausible, NOT proven. **C0 (condition zero)
proves it before any production wiring spreads** (§8).

Construction rules for the implementer:

- **R1 — one creation site, idempotent, fresh-nodes-only.** `ensureMasterSandwich()`
  runs at `reconcile` entry (before any strip wiring — strips connect TO the sandwich)
  AND in `AudioEngine.prepare()` before `engine.start()` (AudioEngine.swift:331-341).
  It only ever attaches fresh nodes and connects fresh edges (the track.add-class
  operation m13-c documents as the live-proven attach-only case, ROADMAP.md:216); it
  never disconnects or detaches anything; the sandwich lives for the PlaybackGraph's
  lifetime (rebuild discards the whole engine — m13-a — so there is no teardown path).
- **R2 — retarget exactly the strip-output sites.** Bus connect
  (PlaybackGraph.swift:484 `engine.connect(node.mixer, to: engine.mainMixerNode, …)`)
  and the fan-out default destination (PlaybackGraph.swift:745 `?? engine.mainMixerNode`)
  become `masterSumMixer`. Grep for any other `mainMixerNode` connect target in
  PlaybackGraph; Metronome/test-tone/meter-tap sites are exempt by policy (§1).
- **R3 — offline parity is automatic** because `OfflineRenderer.render` drives the SAME
  PlaybackGraph reconcile (OfflineRenderer.swift:121-187); manual-rendering mode is
  enabled before reconcile so the sandwich forms at the offline rate like every strip
  connection (OfflineRenderer.swift:134-139). The `_ = engine.mainMixerNode` implicit-
  wiring touch (OfflineRenderer.swift:140-143) stays.
- **R4 — WATCH item carried over**: m13-a §6.6's same-engine restart residual
  (configuration-change recovery). The sandwich is format-negotiated like strip
  connections; the implementer must verify the config-change path treats it identically
  (no new discipline expected, but check).

---

## 2. Stems / mixdown semantics — the contract

Today's law (m11-d, S-3): Σ-stems ≡ mixdown, null residual peak ≤ 1e-4; keyed bounce
byte==stem. It holds because everything downstream of the strips is LINEAR — stem
passes are full-graph renders of subset track lists under one forced full-session PDC
plan (ProjectStore+Render.swift:146-183), and `masterVolume` distributes over the sum
(applied per pass, OfflineRenderer.swift:207). A nonlinear master chain (limiter,
compressor) does not distribute: running it per-stem breaks summation; running it only
on the mixdown breaks Σ-stems≡mixdown. There is no contract under which nonlinear
master processing and per-stem summation coexist — so the law must be RESTATED, not
preserved verbatim.

**DECISION D2: two render classes; the law survives at the master-chain INPUT.**

| Class | Renders | Master chain |
|---|---|---|
| **MASTERED (program)** | `renderMixdown` (ProjectStore.swift:2898 → wire `render.mixdown`), `renderBounce` (ProjectStore+Render.swift:66 → `render.bounce`), `measureLoudness` (ProjectStore+Render.swift:27 → `render.measureLoudness`) | **ACTIVE** |
| **STEM (material)** | `renderStems` per-stem passes (ProjectStore+Render.swift:166), its `includeMixdown` "00 Mixdown.wav" reference (ProjectStore+Render.swift:187), `bounceTrackInPlace` (ProjectStore+Bounce.swift:104), Clip-Fix region render (ProjectStore+ClipFix.swift:130) | **EXCLUDED** (empty chain) |

Restated law, which is what the roadmap's "Σ-stems ≡ mixdown with master chain ACTIVE"
gate line MEANS from now on:

> **S-3′**: With a master chain active in the project, Σ-stems ≡ the master-chain INPUT
> program — i.e. Σ-stems ≡ the stems' own chain-excluded reference render ("00
> Mixdown.wav", same forced targets, same window) with residual peak ≤ 1e-4 — and the
> MASTERED mixdown equals that same program passed through the master chain. With an
> EMPTY master chain the two classes coincide and S-3′ degenerates to the original S-3
> (byte-identical to the m12-b anchors).

Consequences, each deliberate:

- **`measureLoudness` is post-chain.** That is the whole point of the feature — "master
  this for streaming loudness" means the Copilot adds EQ+limiter to master, then
  measures the PROGRAM. Mastered class.
- **Bounce-in-place stays byte==stem BY CONSTRUCTION** — it already reuses the stem
  machinery (StemPlan pass + forced targets, ProjectStore+Bounce.swift:92-108) and both
  sides sit in the STEM class. A track bounce must never bake the master bus into clip
  material; same reasoning for the Clip-Fix region render.
- **Time alignment caveat (document, don't hide)**: a latent master chain (limiter
  lookahead ≈ 240 samples @48 k, EngineProtocol.swift:210) delays the MASTERED program
  relative to Σ-stems by its active latency. The classes are therefore never compared
  sample-wise with a latent chain; the C2/C3 gates are constructed accordingly (peak/
  loudness analytics + a zero-latency linear-unity equivalence check).
- **NO `includeMasterChain` option on `render.stems` in v1.** New optional params are
  allowed by the rules, but this one buys nothing sound: "mastered stems" have no
  summation-valid semantics (that is stem-mastering, a different product feature), and
  an agent wanting a mastered file calls `render.bounce`. Additive later if ever needed.
  0 new commands, 0 new params.
- **Additive honesty field**: `render.stems` result gains `"masterChain": "excluded"`
  when (and only when) the project carries a non-empty master chain — so an agent
  cannot mistake stems for mastered deliverables. Result-shape additive, not a param.

**Rejected alternative — stems THROUGH the master chain.** Breaks Σ-stems≡anything
(nonlinear per-subset processing), destroys inter-stem balance exactly like the
per-stem normalization the current doc comment forbids (ProjectStore+Render.swift:132-134),
and would silently change `bounceInPlace` material. Industry consensus is stems
pre-master for this exact reason. Loses on correctness, not taste.

**Rejected alternative — retire the law.** The Σ-stems oracle is the project's single
most-reused verification instrument (m11-e, m12-f, m13-a all leaned on it). Restating
at the chain input keeps it as a permanent gate; retiring it deletes our best
regression tripwire.

### 2.1 Plumbing the split (engine seam)

`AudioEngineControlling` changes (EngineProtocol.swift):

- **NEW** `func masterEffectsChanged(_ effects: [EffectDescriptor])` — the
  `masterVolumeChanged` twin (EngineProtocol.swift:168); default no-op in the protocol
  extension (the `projectWillReplace` precedent, EngineProtocol.swift:363) so fakes and
  headless engines compile unchanged. Live behavior: cache `lastMasterEffects`, hand to
  the graph, run one `applyParameters` pass (chain sync + PDC recompute funnel —
  §5/R6). `rebuildEngine` republishes it during cold build.
- **CHANGED** `renderOffline(…)` (EngineProtocol.swift:187-189) and `renderMixdown(…)`
  (EngineProtocol.swift:174-176) gain `masterEffects: [EffectDescriptor]`. Protocol
  requirements cannot default parameters — GOOD: every call site is forced to declare
  its render class explicitly. All seven call sites and their class assignments are the
  table above (plus AudioEngine.swift:908, renderMixdown's internal delegation —
  forwards its own parameter). Extension defaults (EngineProtocol.swift:416-420)
  updated; conformer/fake fixups are mechanical.
- `offlineCompensationTargets` is UNCHANGED — the master chain is common-path and never
  a plan input (§5), so per-strip forced targets cannot depend on it.
- `OfflineRenderer.render`/`renderToWAV` gain `masterEffects: [EffectDescriptor] = []`
  (class-level default IS allowed here and keeps the large engine test surface
  compiling; the class decision lives at the protocol/store layer, which has no
  default). Built-ins only (§4) means `prepareAudioUnits` needs NO master loop in v1.

---

## 3. Recording-guard interaction (m13-c)

**DECISION D3: master chain verbs are chain publishes — LEGAL mid-recording; the guard's
decision table does not grow.** With D1 the sandwich is permanent: master
fx.add/remove/reorder/setParam/setBypass never create, sever, or re-route a graph edge
— they are exactly the m13-c LEGAL set's `fx.add`/"plain `fx.reorder`"/param-only class
(ROADMAP.md:216: guarded-set membership is decided by ANNOUNCE-CAPABILITY, not verb
name). The two announce-capable fx cases cannot arise on master: `fx.setSidechain` is
rejected outright for master (§4 — a validation error, not the recording guard), and a
master `fx.remove` can never be keyed removal because a master effect can never carry
`sidechainSourceTrackID` (invariant enforced at the store + sanitized on load, §4/§6).
`requireRoutingMutationAllowed` is NOT called by any master chain method. Pin it: the
m13-c `legalVerbsRemainUnguarded` test (RecordingStoreTests) grows master rows, and C4
exercises a master `fx.add` live during a rolling take.

---

## 4. Addressing, store surface, errors, catalog

**DECISION D4: `trackId:"master"` sentinel via a dedicated `FXTarget` resolution helper —
NOT through `requireTrackID`.** `requireTrackID` (Commands.swift:3855) is shared by
dozens of non-fx verbs where "master" must remain invalid; widening it would silently
change their error surfaces. Instead Commands.swift gains one
`parseFXTarget(_ params:) -> FXTarget` (`enum FXTarget { case track(UUID); case master }`;
the sentinel is the exact lowercase string `"master"`, nothing fuzzy), used by exactly
the five chain verbs. `fx.describe`/`fx.listAudioUnits` take no trackId — untouched.

| Verb | `trackId:"master"` | Behavior |
|---|---|---|
| `fx.add` | ACCEPTED (built-in kinds only) | `store.addMasterEffect(kind:at:)`; `kind:"audioUnit"` → named error below |
| `fx.remove` | ACCEPTED | `store.removeMasterEffect(effectID:)` |
| `fx.reorder` | ACCEPTED | `store.reorderMasterEffect(effectID:toIndex:)` |
| `fx.setBypass` | ACCEPTED | `store.setMasterEffectBypassed(…)` |
| `fx.setParam` | ACCEPTED | `store.setMasterEffectParam(…)` |
| `fx.setSidechain` | REJECTED (named) | also rejects `sourceTrackId:"master"` (named), upgrading today's raw UUID-parse error at Commands.swift:813-815 |

**Named teaching errors (verbatim, gate-checked in C6):**

- `ProjectError.sidechainMasterUnsupported` → `"the master chain cannot host a sidechain-keyed effect — key an effect on a track or bus instead"`
- master as key source (wire-level, fx.setSidechain) → `"the master output cannot be a sidechain key source"`
- `ProjectError.masterChainBuiltInOnly` → `"the master chain hosts built-in effects only in v1 — pick one of gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus"`

**DECISION D4a: built-in effects only on master in v1.** Allowing hosted AUs would drag
in the live prepare scan (`syncAudioUnitEffects`, AudioEngine.swift:751-800, keyed by
owning trackID), offline AU preparation (OfflineRenderer.swift:99-108), AU state capture
at save, and plugin-window plumbing — a large risk surface for zero gain on the audit
use case (EQ + limiter, both built-ins). The AU picker round (m13-g) is the natural
place to lift this. The store enforces; the wire surfaces via the LocalizedError
mapping (the fx.* convention, Commands.swift:709-710).

**Store surface (DAWCore/ProjectStore)**: `masterEffects: [EffectDescriptor]` state +
five master methods mirroring the track ones (guards outside the edit body, shared
`maxEffectsPerChain` 16 / `chainFull` — ProjectStore.swift:1212-1236), undo labels
`"Add <Effect> to Master"` / `"Remove <Effect> from Master"` / `"Reorder Master
Effects"` / bypass label mirror, setParam coalescing key scoped
`master.<effectID>.<param>` (mirror the track key shape). Engine push: every mutation
AND every undo/redo/project-boundary state restore calls
`engine.masterEffectsChanged(masterEffects)` — the implementer must ride the SAME
restore funnel that re-pushes `masterVolume` today (grep `masterVolumeChanged` call
sites in ProjectStore; every one of them gains the twin call). `project.new` resets to
`[]`.

**Snapshot (BOTH surfaces — the m12-f MIRROR-DTO trap, named sites):**

1. `ProjectSnapshot` (Model.swift:1043) gains `masterEffects: [EffectDescriptor]`
   (default `[]`), populated in `ProjectStore.snapshot()` (ProjectStore.swift:3693-3716).
2. Wire `snapshotJSON` (Commands.swift:3674-3741) gains top-level
   `root["masterEffects"] = effectsJSON(...)` — ALWAYS present (empty array), matching
   the per-track `effects` field which is set unconditionally (Commands.swift:3690),
   reusing `Commands.effectsJSON` (Commands.swift:2847/2855) with a master latency
   resolver. The stale comment "the master strip carries no chain today"
   (Commands.swift:3733-3734) is rewritten. `pdc` object gains additive
   `masterChainLatencySamples` (§5).

**Persistence (the third mirror surface):** `ProjectDocument` (ProjectDocument.swift:12)
gains `masterEffects: [EffectDocument]?` — omit-when-empty via the exact
`grooveTemplates`/`markers` pattern (ProjectDocument.swift:76-81, decodeIfPresent at
:107-109), REUSING `EffectDocument` (ProjectDocument.swift:488-534 — the m12-f-repaired
DTO that already round-trips `sidechainSourceTrackID`; for master it stays nil forever).
`runtimeState` (ProjectDocument.swift:126-128) returns `masterEffects` alongside
`masterVolume` and SANITIZES v1 invariants on load: an entry of kind `audioUnit` is
dropped with a warning; a non-nil `sidechainSourceTrackID` is cleared with a warning
(the runtimeState warnings precedent). Save-site: the `ProjectDocument` build init
(ProjectDocument.swift:60-93) gains the parameter; both ProjectStore save paths pass it.
An empty chain writes NO key → pre-m13-d saves stay byte-identical (C5).

**Copilot catalog: 47 → 51.** Today the catalog contains only ONE fx verb —
`fx.setSidechain` (CopilotCatalog.swift:532; full 47-entry list verified by grep) — so
the Copilot literally cannot add an effect anywhere, which is the audit's F4 phrased
differently. Add `fx.add`, `fx.remove`, `fx.setParam`, `fx.setBypass` (each description
teaching `trackId:"master"`, built-ins-only on master, and the mastering recipe: EQ then
limiter, then `render.measureLoudness`); update `fx.setSidechain`'s description with the
master rejection. CopilotCatalogTests count pin 47→51. (Law reminder: `ai.copilotState`
does NOT embed the catalog — verify via source grep + CopilotCatalogTests.)

**Explain: 65 → 66** — one new topic (`.mixerMasterInserts`) on the master strip's
inserts section; master-specific copy ("processes the whole mix — the last stop before
your speakers").

**MCP (0 new tools, no renames; 122 pin HELD):** `fx_add`/`fx_remove`/`fx_reorder`/
`fx_set_bypass`/`fx_set_param` descriptions teach the sentinel; their `trackId` zod
schemas must ACCEPT `"master"` — if any is `z.string().uuid()`, relax those five to
`z.union([z.string().uuid(), z.literal("master")])`; `fx_set_sidechain` description
gains the master rejection note and its schema stays UUID-only (rejection is
deliberate). Wire count 119 pin HELD (0 new commands).

---

## 5. PDC

**DECISION D5: master chain latency is REPORT-ONLY, the ACTIVE sum, and the master is
never a plan input.** The planner's contract already says it: "The master strip is
common-path (delays everything equally) and must NOT be passed as an input strip"
(LatencyCompensation.swift:18-19), and `PDCInput` deliberately excludes it
(LatencyCompensation.swift:83-85). A post-sum chain delays every strip identically —
there is nothing to skew and nothing any per-strip ring could or should correct. What
changes:

- `recomputeCompensation` (PlaybackGraph.swift:945-1020) feeds
  `masterChainState.latencySamples` — the ACTIVE (non-bypassed) sum, the
  `EffectChainState.latencySamples` semantics (PlaybackGraph.swift:876-881) — into the
  `PDCReport` init instead of the literal 0 at PlaybackGraph.swift:1018. Rationale for
  ACTIVE over ALL: the strips use the ALL sum for bypass-stability because their rings
  absorb the difference (LatencyCompensation.swift:13-16); the master has no ring, so
  the honest ruler-to-speaker figure is the real signal delay, and it legitimately
  moves when a master effect is bypassed. `outputLatencySamples = T + B + master`
  then goes live exactly as the field was designed
  (LatencyCompensation.swift:308-312, 320-322).
- **R6 (ordering)**: `applyParameters` syncs the master chain state
  (`masterChainState.sync(descriptors: masterEffects, sampleRate:)`, the
  EffectChainProcessor.swift:243 signature, same pass position as the per-strip sync at
  PlaybackGraph.swift:1098) BEFORE `recomputeCompensation` runs at the pass tail — so
  the recompute funnel (PlaybackGraph.swift:931-939, the "six events" list) gains its
  seventh event, master chain edit, with no new recompute site.
- Per-strip `compensationSamples` MUST be provably unaffected by the master chain
  (C7 asserts targets identical before/after adding a latent master chain).
- Snapshot: `pdc.masterChainLatencySamples` additive field (Commands.swift:3735-3740
  object) + `outputLatencySamples` now moves. Honest recording note for the docs: a
  latent master chain delays MONITORED playback by its active latency during tracking;
  reported, never corrected (v1 — the skew-report precedent,
  LatencyCompensation.swift:106-115).

---

## 6. UI scope (d-2)

Pro density only — Simple hides inserts everywhere (the density honesty rule; the
per-strip sections are Pro-gated at MixerStripView.swift:37, 44-55). Changes:

- `MixerMasterStrip` (MixerStripView.swift:356-400) gains `densityStore:
  PanelDensityStore` (same `MixerView.panelID` read as the channel strips) and, in Pro,
  an inserts section between the header and the fader block.
- **Reuse, not new primitives**: `insertsSection`/`addMenu`/`InsertRow`
  (MixerStripView.swift:125-179) generalized over the target — `InsertRow` and the
  add-menu take an `FXTarget`-shaped handle (or `trackID: UUID?` with nil = master)
  routing to the master store methods; `addableEffectKinds` (MixerStripView.swift:8-9)
  is already exactly the built-in set = exactly what master accepts, so the menu needs
  no filtering. No `onOpenWindow` on master (built-ins only, v1 — the AU branch stays
  track-only).
- The stale absence comment at MixerStripView.swift:352-355 is retired.
- Pixel captures both densities (C8): Pro master strip with a 2-insert chain (EQ +
  limiter, one bypassed) and Simple proving the section hides.

---

## 7. Implementation split

**d-1 — core / engine / persistence / render contract (audio-dsp-engineer):**
C0 spike FIRST; PlaybackGraph sandwich (R1-R4) + master `EffectChainState` + sync (R6)
+ PDC feed (§5); `AudioEngineControlling` changes + fake/conformer fixups +
`OfflineRenderer` param (§2.1); DAWCore: `masterEffects` state + five store methods +
undo/restore funnel + render-class assignments at all seven call sites (§2 table);
persistence all three mirror surfaces + load sanitization (§4); ARCHITECTURE.md PDC
master-exclusion paragraph + "Key future decisions" SETTLED entry. Gates C0, C1, C2,
C3, C5, C7. Everything here is headless-testable: `renderStems`/`renderBounce`/
`bounceTrackInPlace` are store methods callable from Swift Testing suites with a real
offline engine, and the null byte gate runs over the EXISTING wire (empty chain is the
default — no d-2 dependency).

**d-2 — wire / MCP / catalog / Explain / UI (swift-app-engineer, MCP bits inline):**
`FXTarget` helper + five handler branches + the three named errors incl. the
`sourceTrackId:"master"` upgrade (§4); `snapshotJSON` masterEffects + pdc field +
comment rewrite; catalog 47→51 + CopilotCatalogTests; Explain 66; MCP descriptions +
zod relax (five tools); master strip UI (§6). Gates C4, C6, C8, plus a C1 re-run
(d-2 must not move bytes).

Two cycles are justified: d-1 alone touches a protocol, the graph, persistence, and
four byte-level gates; d-2 is a full wire+UI+MCP surface with live gates. d-2 depends
on d-1's store methods; no interleaving.

**Explicitly NOT required from Xcode**: everything above runs in the bare-SPM
environment — ChainHostAU is in-process registration, no entitlements, no AUv3
packaging (ChainHostAU.swift:6-14). No full-Xcode dependency anywhere in m13-d.

---

## 8. Conditions (gate form)

- **C0 — bit-transparency spike (condition zero, KEPT test, before production wiring
  spreads).** `MasterSandwichTransparencyTests` (m12-a `SidechainBusSpikeTests`
  precedent): offline-render a representative session (audio + instrument + bus + send
  + per-track effects, non-unity masterVolume) through (a) today's shape and (b) a
  hand-built graph with the D1 sandwich (empty chain) — assert BYTE-IDENTICAL buffers;
  then reproduce the m12-b anchor SHAs through the sandwich build. FAIL → fallback
  topology §1-B (post-fader insert + honest tap relocation) under the same byte gate;
  BOTH fail → STOP, report the differing-sample shape, do not ship.
- **C1 — null-case byte gate (the next anchor era).** Empty master chain; the full
  m12-b oracle byte-identical over the wire (mix `b4c56164…` ×2 determinism, window
  `a14f4615…`, stems ×3, bounce==stem). Run after d-1, re-run after d-2.
- **C2 — analytic master-limiter ceiling.** Program a sine driven above ceiling C;
  master chain = EQ (neutral) + limiter(ceiling C): `render.bounce` true peak ≤ C + ε
  (analytic, the keyed-comp closed-form style) while Σ-stems true peak > C (proves
  stems are pre-chain and the mastered path is post-chain — one discriminating pair).
- **C3 — stems contract (S-3′).** With the C2 chain ACTIVE: Σ-stems vs the
  chain-excluded "00 Mixdown.wav" reference ≤ 1e-4 residual peak; `render.stems`
  result carries `masterChain:"excluded"`; `bounceTrackInPlace` sha == that track's
  stem sha (both stem-class); linear-unity check: master chain = gain@0 dB →
  mastered mixdown ≡ empty-chain mixdown ≤ 1e-4 (zero-latency linear effect, so
  sample-wise comparison is valid).
- **C4 — live add, zero interruption + recording legality.** Staging, playing:
  `fx.add {trackId:"master", kind:"eq"}` then `…"limiter"` MID-PLAY — playhead
  monotone across the calls (no restart), no rebuild log line, meters continuous,
  `mixer.masterAnalysis` reflects the ceiling. Then during a ROLLING take: master
  fx.add/setParam SUCCEED (D3), take completes intact.
- **C5 — persistence / mirror-DTO.** Save with a master chain (edited params, one
  bypassed) → reopen → deep-equal incl. order/bypass/params, through ProjectBundle
  (NOT descriptor Codable — the m12-f lesson); wire snapshot shows `masterEffects`
  after reopen (the second mirror); empty-chain save byte-identical to a pre-m13-d
  save of the same session; hand-edited `project.json` with an audioUnit-kind /
  keyed master entry loads SANITIZED with warnings.
- **C6 — wire/MCP surface.** Counts HELD 119/122; catalog 51; Explain 66; snapshot
  `masterEffects` always present + `pdc.masterChainLatencySamples`; the three teaching
  errors verbatim; sentinel round-trip live on all five verbs; zod accepts "master" on
  exactly those five; `fx.setSidechain` master rejections (both directions) verbatim.
- **C7 — PDC.** Limiter on master → `pdc.outputLatencySamples` = maxPath + 240 @48 k;
  bypass it → back to maxPath (ACTIVE-sum rule); per-strip `compensationSamples`
  byte-equal before/after the master chain exists (common-path proof).
- **C8 — pixel captures, both densities**, per §6, pixel-reviewed.
- **C9 — docs.** ARCHITECTURE.md (PDC master paragraph + Key-decisions SETTLED entry);
  the two stale in-code comments (Commands.swift:3733-3734, MixerStripView.swift:352-355)
  rewritten; ROADMAP m13-d record.

---

## 9. Failure modes considered

1. **Sandwich not bit-transparent** → caught by C0 before anything else lands; fallback
   ladder is explicit (§8-C0). This is the only unknown that could sink D1.
2. **Mirror-DTO silent data loss** (the m12-f trap) → three surfaces named file-exact
   (§4), C5 pins disk + wire + reopen, never descriptor Codable alone.
3. **Accidental announce from sandwich creation on a once-rendered engine** → R1
   restricts creation to attach+connect of fresh nodes (the proven track.add class) and
   places it at prepare-pre-start / reconcile-entry; unit-pin in the
   EngineRebuildTests style that `ensureMasterSandwich` never sets `needsEngineRebuild`.
4. **Master fader double-application** → the fader lives ONLY on `mainMixerNode`
   (§1); masterSumMixer parameters never touched; C1 would catch any violation as a
   level change.
5. **Stems silently mastered (or mixdowns silently un-mastered) by a future caller** →
   the protocol parameter has NO default, so every call site declares its class; the
   §2 table is the normative classification, and the `masterChain:"excluded"` result
   field keeps agents honest.
6. **Recording-guard drift** → D3 documents WHY master verbs are unguarded
   (announce-capability, not verb name); the legal-set test grows master rows so a
   future guard cannot overreach silently.
7. **RT safety** → zero new render-thread code: the master chain renders inside the
   existing ChainHostAU render block (allocation-free, atomic-publish fed,
   ChainHostAU.swift:213-309); all new work is main-actor publishes and offline policy.

## 10. Verdict

**GO-WITH-CONDITIONS.** Condition zero is the C0 bit-transparency spike; the null-case
byte gate (C1) is the first full-system condition and the m12-b anchors remain the
permanent oracle. No new architecture: the engine shape is the proven strip sandwich in
one new position, the wire is a sentinel on five existing verbs, and the stems law
survives — restated once, precisely, at the master-chain input.
