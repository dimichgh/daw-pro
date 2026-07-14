# m16-h design — the AVFoundation reconfig defect, named: deep post-start subtrees never accept player starts

Date: 2026-07-13
Author: daw-architect (agent)
Status: **DESIGN SETTLED, GO** — deterministic repro (8/8 failing cells across 4 staging instances, two scales, two engine generations), mechanism reproduced in a **30-line pure-AVFoundation standalone** (no DAW code), fix decided and pre-validated live through an equivalent path. Implementer: audio-dsp-engineer.
Supersedes/adjusts: `design-m16a-canvas-crash.md` §4-A1's mechanism sketch (right lead, wrong emphasis — see §3.4); closes rider R3; explains the m16-f probe3 "one instance" anomaly (it was not an anomaly — see §3.5).
Laws honored: the m13-a teardown laws (engine-discard, never surgical detach of once-rendered engines) are **not touched and are re-validated by this design** — cold build is precisely the shape that works. The M14 restart law (a restarted play keeps the schedule) is untouched.

---

## 1. Executive summary

**The defect.** On this OS (macOS 26.4 / Darwin 25.4.0, all m13→m16 evidence eras), an `AVAudioPlayerNode` whose path to the pre-existing active render graph crosses **two or more nodes that were attached+connected while the engine was RUNNING** can never be started: `play(at:)` raises `"player started when in a disconnected state"` — deterministically, permanently, regardless of connect order, node types (plain mixers fail; a single AU hop is fine), settle time, or disconnect/reconnect repair attempts. The public API (`outputConnectionPoints`) shows a healthy connection throughout; AVFAudio's internal player-start bookkeeping has no public mirror. A **one-node-deep** post-start path is fine; **attach-before-start is always fine**.

**Why DAW Pro bleeds everywhere.** Every DAW strip is a 3-deep sandwich (`player → sumMixer → ChainHostAU → stripMixer → mainMixer`). So any strip **born while the engine is running** is a dead player host. Two flows birth strips on running engines:
1. **`project.new` on a once-rendered engine** — `rebuildEngine` (m13-a A1) cold-builds the *empty* new project and then **unconditionally starts** the fresh engine; every track/clip the user or an agent adds afterwards attaches to that running engine → **all audio clips of the session are silent** (honest `clip-unplayable` notices, wire alive) until an announce-class rebuild or `project.open` heals it. Deterministic from cycle 2 of any play-bearing session: measured 8/8 across 40-strip and 2-strip scales.
2. **`track.add` after the first play in any session** (gen-1 engines too — this was never rebuild-specific): the new track's clips raise on every start pass. Measured: 40/40 dead on a played-empty-project engine (E4b).

**The fix (two legs, both m13-a-lawful, both control-plane):**
- **Leg 1 — `rebuildEngine` defers `engine.start()`** until something actually needs a running engine (pending playback resume, armed-instrument live-thru). Every other consumer already lazily starts via `prepare()`. Result: after `project.new`, strips attach to a **never-started** engine (the offline/cold shape — the single most-proven regime in the tree) and the first play starts the engine with everything start-era.
- **Leg 2 — strip birth on a RUNNING once-rendered engine is announce-class**: reconcile flags `needsEngineRebuild` (the existing m13-a announce/abort machinery, same choke point) before creating a strip sandwich when `engineHasRun && engine.isRunning`; `rebuildEngine` then cold-builds with the new strip included. Composed with Leg 1, a post-play 40-track storm costs **one** rebuild (the rebuilt engine is left stopped; the remaining 39 strips attach cold).

Clip players attaching to **start-era strips** while running are clean (proven three ways) and keep today's zero-cost path — the daily "import a clip onto an existing track" flow never rebuilds.

---

## 2. Evidence — live DAW experiments (all 2026-07-13, this tree, `swift build` debug binary)

Staging law compliance: fresh ports 17681–17685, one instance at a time, `project.new {discardChanges:true}` normalization, exact-pid kills, ports verified closed after, **.ips ledger byte-identical before/after the whole campaign** (20 `DAWApp-*.ips` entries — note: 4 fewer than the mandate's "24"; the delta predates this session, ledger snapshots in scratchpad `m16h-ips-{before,after}.txt`). Audibility = `debug.masterCapture` → 10 ms-window peak RMS (threshold 0.01); every SILENT/AUDIBLE verdict below is a capture measurement, not an inference (the masking lesson).

| # | Experiment (instance) | Result |
|---|---|---|
| E1 | **The probe3 shape ×4 cycles** (A, 17681): per cycle `project.new` → 40 tone strips + 1 strip with 16 limiters → warm play/stop → capture play | **cycle 1 AUDIBLE (0.50); cycles 2–4 SILENT (0.0000), `clip-unplayable` ×80 each (40 clips × 2 start passes)** — deterministic, no churn needed |
| E2 | Metronome in the dead state (A) | **click AUDIBLE (0.21)** while all 40 clips raise — metronome attaches in `rebuildEngine` BEFORE `engine.start()` (AudioEngine.swift:825), strips after |
| E3 | Heal via announce-class rebuild (A): `track.add {kind:bus}` + `track.addSend` on the dead 41-strip project | **AUDIBLE (0.52) immediately and stays healed** — rebuild-with-tracks (strips cold-built pre-start) is a complete cure; this pre-validates the fix's core shape |
| E4 | Small scale ×4 cycles, 2 strips, 0 limiters (B, 17682) | **identical: cycle 1 AUDIBLE, cycles 2–4 SILENT ×4 notices** — scale is irrelevant; *every* once-rendered `project.new` session is affected |
| E6 | Instrument track added in the dead state (B): PolySynth + MIDI notes | **AUDIBLE (0.14)** — `AVAudioSourceNode` strips render fine post-start; the defect is player-start-specific. Corollary: a dead-state session's instruments sound while its audio clips don't, with **no notice for the asymmetry** |
| E4b | **Gen-1 engine** (C, 17683): fresh app → play EMPTY project → stop → add 40 strips to the running never-rebuilt engine → play | **SILENT, 40 raises** — the defect is NOT rebuild-specific; any running engine kills subsequently-born strips |
| E7 | `project.open` a saved 41-strip project on the same once-rendered instance (C) | **AUDIBLE (0.51), zero notices** — open/recover boundaries carry tracks INTO the boundary reconcile → strips are start-era → immune (why m16-c's live probes were clean) |
| E8 | Race test (C): `project.new` → 3 s settle → 2 strips added 150 ms apart → play | **SILENT** — not a race; structural |
| E9 | Strip-era split (D, 17684): T1+C1 built pre-start (plays); then while running: C2 → T1 (start-era strip) and T2+C3 (post-start strip), isolated play windows | **C2: AUDIBLE, ZERO raises** (the daily import-onto-existing-track flow is clean). **C3: raises on EVERY pass** (count 1→2→3 across replays) **yet its window measured AUDIBLE** (grade B, §3.3); seek-while-stopped verified genuine (silent-region window silent, playhead advanced) |
| E10 | Grade split (F, 17685): dead gen-2 state → heal via announce → add ONE more track+clip post-heal | dead state SILENT ✓, healed AUDIBLE ✓, **post-heal new strip SILENT + raise** (grade A) — grade B did not recur on a rebuilt engine; splitter under-determined (§3.3) |

Raise counts cross-checked in app stderr (`PlaybackGraph: play raised … clip skipped`): A=320, B/C/D/F consistent with every SILENT/raising pass; all raises took the m16-a per-node barrier path (predicate passed — public connection points exist), zero crashes, zero wedges, zero `engine-exception`.

### 2.1 The m16-f archaeology, closed

The m16-f session's own logs (preserved in this session's shared scratchpad) settle the "one staging instance" story: `m16f-staging.log` carries **4880 raises** (= 40 clips × 2 plays + 120 seek-restarts × 40 — a full probe3b run with every pass raising); the m16-f session's *first* post-fix probe3 capture (`m16f-analyze3.log`, 2,011,200 frames) contains **zero active segments — totally silent** — and the "passing" 61-segment re-run (`m16f-analyze3b.log`) was made against a **freshly launched instance**, i.e. cycle 1 of a never-run engine, the one immune cell. Nothing was nondeterministic: the fresh instance passed *because* it was fresh. The mandate's "ordinary sessions appear unaffected" generalization is **false**: m15-e/m16-c probes were open/recover-based or fresh-launch shapes (immune); the m16-a C1 gate's only audio clip is *supposed* to be unplayable, so it is structurally blind to this defect (§6, C6).

## 3. Root cause, named at the mechanism level

### 3.1 The standalone matrix (pure AVFoundation, no DAW code — `avf-cells*.swift` + the repo's `DAWCatchObjCException`, scratchpad)

Engine started, then a player + subtree attached/connected **while running**; `play()` under an ObjC catch; mainMixer tap RMS measured. 19 cells:

| Cell | Shape (all post-start unless noted) | play() | RMS |
|---|---|---|---|
| F | player attached BEFORE start (control) | OK | 0.21 |
| A / A2 | player → mainMixer (depth 0), ±2 s settle | OK | 0.21 |
| B | parked player existed at start; new player → mainMixer | OK | 0.21 |
| C | player → submixer → mainMixer (depth 1) | OK | 0.21 |
| N | player → EQ(AU) → mainMixer (depth 1, AU hop) | OK | 0.21 |
| G | player → START-ERA submixer (the E9-C2 cell) | OK | 0.21 |
| **L** | player → sub → mix → mainMixer (**depth 2, plain mixers**) | **RAISED** | **0.0** |
| **M** | player → TimePitch(AU) → mix (depth 2) | **RAISED** | **0.0** |
| **I / K / J** | the DAW strip shape sum→EQ→mix (depth 3), with/without a master AU, with/without a parked start-era strip | **RAISED** | **0.0** |
| I8 / I9 / J2 | two-pass (strip first, player 1 s later) | **RAISED** | 0.0 |
| **L2 / I10** | **downstream-first connect order** (live edge first, then upstream) | **RAISED** | 0.0 |
| Z1 / Z2 | heal attempts: disconnect+reconnect the player edge / the subtree's live edge | **RAISED again** | 0.0 |
| Z3 | a **fresh player object** onto the stale subtree | **RAISED** | 0.0 |

### 3.2 The named mechanism

**`AVAudioEngine`'s running-engine reconfig (`UpdateGraphAfterReconfig`) does not propagate player-start eligibility more than one edge above the pre-existing active graph.** A player whose downstream path crosses ≥2 post-start nodes is *permanently* invisible to `AVAudioPlayerNodeImpl::StartImpl`'s connectivity check — while the *render* integration is transitive (deep post-start source-node subtrees render fine, E6), and the *public* connection surface (`outputConnectionPoints`) reports healthy edges. The stale state survives settle time, connect-order permutations, edge re-connection, and fresh player objects on the same subtree (Z1–Z3): it is a property of the **subtree's integration era**, not of the player object, and it is **unreachable through the public API** — the third confirmed instance (after M9 and m13-a) of AVFoundation private bookkeeping defeating a surgical model, and the second time cold-build-from-scratch is the only reliable shape.

Distinguishing "genuinely unwired" from "stale bookkeeping": the players are **genuinely absent from the active render graph as start targets** (dead grade: no signal at the tap) even though edges exist publicly; simultaneously the *same* reconfig pass integrates non-player sources transitively. Both halves are internal AVFAudio state with no public mirror; the raise is the only observable, and the m16-a per-node barrier already converts it honestly.

### 3.3 The two grades (recorded honestly)

- **Grade A — raise + dead** (the norm): every standalone deep cell; every DAW post-start strip on instances A/B/C/F (50+ player-start passes, 100%).
- **Grade B — raise on every pass, yet audible**: observed on exactly one configuration (instance D: gen-1 engine started with one strip+player; a later post-start strip's clip raised each pass *and* measured full-level audio at the anchor; seek verified genuine). Not reproduced on a healed/rebuilt engine (E10) nor in any standalone cell. The splitter is **under-determined** (suspects: per-strip meter taps forcing render integration; gen-1 vs rebuilt engine internals). Not load-bearing: the fix removes the *raise class* — both grades become impossible by construction — and the C-gates assert audibility directly, so the fix cannot hide behind grade B.

### 3.4 Correction to the m16-a A1 record

A1's "rebuildEngine starts the fresh EMPTY engine first, and strips then attach to a RUNNING engine" was the right lead but incomplete in two load-bearing ways: (1) the poison is **not rebuild-specific** — gen-1 engines kill post-start strips identically (E4b); (2) "attach to a running engine" is fine at depth ≤1 (metronome, tone player, clip-onto-existing-strip) — the killer is the **strip sandwich's depth ≥2**. "Iteration 1 survives because the never-run engine wires strips before first start" stands verbatim.

### 3.5 Blast radius on this tree (pre-fix)

Silent-with-honest-notice: **every** audio clip added after `project.new` on a once-rendered engine (the File→New daily flow, agent storms, every gate that cycles projects); every clip on a track created after the session's first play (includes a track.add→record→playback flow). Silent with **no notice**: none known (instruments render; the notice fires for every dead player). Immune: fresh-launch sessions until their first `project.new`; `project.open`/`project.recover`; clips added to pre-play tracks; clips added to start-era strips post-play; anything after any announce-class edit (send/output/sidechain/routed-teardown — which is why interesting mixing sessions self-heal and the defect hid this long).

## 4. The fix decision

**Adopt Legs 1+2 (defer rebuild start + announce on strip birth while running).** Rationale: it converts every player-bearing attach into one of the two proven-clean regimes (attach-before-start, or depth-≤1/start-era attach), using only machinery that already exists and is crash-campaign-hardened (the m13-a announce/abort/rebuild path, `prepare()`'s lazy start). Zero wire surface change, zero render-thread surface, no new AVFoundation bets.

### Alternatives and why they lose (all falsified by experiment, not taste)

1. **Downstream-first connect ordering in `makeStripSandwich`** — falsified: L2/I10 raise identically; the reconfig walker is order-insensitive.
2. **Surgical re-bind after attach** (disconnect/reconnect edges, fresh player objects) — falsified: Z1/Z2/Z3; also philosophically dead (third private-bookkeeping bet).
3. **Keel player** (guarantee ≥1 start-era player) — falsified: J/J2 raise with a parked start-era strip+player.
4. **Stop→start bounce around attachment** — forbidden by the m13-a laws (nodes that rendered and sat attached across a stop→start boundary poison later detaches — the falsified M9 flush) and audibly disruptive per add; not tested further on principle.
5. **Flatten the graph to depth ≤1** — a whole-mixer-architecture rewrite (loses insert sandwiches, buses, PDC structure) to dodge one framework defect; absurd cost.
6. **Leg 1 alone** — leaves E4b-class dead (play-empty-then-build; post-play track.add).
7. **Leg 2 alone** — without Leg 1 every rebuild restarts the engine, so a 40-track storm = 40 rebuild bounces (O(n) rebuild storms — also the RSS-rider environment). Leg 1 caps a stopped-transport storm at exactly one rebuild.

### Failure modes of the fix, and their guards

- **A start-needing consumer missed by Leg 1's condition** (engine left stopped when something needed it): the known consumers all lazily `prepare()` (transport start AudioEngine.swift:594, record :1522, test tone :2157, watchdog-thru :2144); the two that don't are playback-resume and armed-instrument live-thru — exactly Leg 1's start conditions. `debug.masterCapture` already *refuses* a stopped engine with a teaching error (behavior unchanged; probe scripts already warm up by law). Guard: C7 unit pins + C2/C3 live gates.
- **A strip-birth path that skips the announce** (a future reconcile refactor re-introducing attach-while-running): guard: C7's headless pin (strip birth on a running once-rendered engine ⇒ `needsEngineRebuild` before any attach) + the C1 audibility gate as the permanent regression tripwire; the m16-a per-node barrier stays as defense-in-depth (raises convert to notices, never crashes).
- **Mid-play storms** (track.add during playback): each birth = wind-down + rebuild + resume — the established send-add interruption class (m13-a C2 budget ≤300 ms at 41 strips). Accepted and gated (C4). Storms while stopped cost one rebuild total.
- **Rebuild-without-start leaves `engineHasRun == false`**, so pre-play editing after `project.new` runs the never-run cold regime (direct detaches, no announces) — this is *literally the fresh-launch regime*, the most-tested state in the suite; teardownDetach's never-run branch is sanctioned (PlaybackGraph.swift:530–536).
- **Offline paths**: untouched by construction — `OfflineRenderer` builds its own never-started engines; Leg 2 guards on `engine.isRunning` (false under manual-rendering cold builds at reconcile time). Era anchors gate it (C8).

### RT-safety statement

Zero render-thread changes. Both legs are main-actor control-plane decisions (whether to call `engine.start()`, whether to flag a rebuild). No new atomics, no new locks, no allocation changes on any render path. The M14 restart law is untouched (no change to `startPlayers`/schedules/loop machinery).

## 5. Implementation plan

1. **Leg 1** — `Sources/DAWEngine/AudioEngine.swift`, `rebuildEngine(reason:)` (:773; the cold-build block :815–845): replace the unconditional `engine.prepare(); try engine.start()` with a needs-start decision: `let mustStart = resumeAfterRoutingRewire != nil || lastTracks.contains { $0.kind == .instrument && $0.isArmed }`. When false: skip prepare/start/watchdog-arm, leave `isRunning = false` and `graph.engineHasRun = false`; keep the full cold build (master sandwich, meter tap install, metronome attach, reconcile, pre-start volume/parameter pass) exactly as-is — `prepare()` (:509) already re-applies parameters and re-arms the watchdog on the eventual start (the double-apply convention holds by existing code). When true: current behavior verbatim (start, post-start parameter pass, watchdog, resume via `startPlayers(renderClockTrusted: false)`).
2. **Leg 2** — `Sources/DAWEngine/PlaybackGraph.swift`, `reconcile(tracks:)`: at audio-strip birth (the `addTrackNode` call, :699) and bus birth (:606–616), when `engineHasRun && engine.isRunning`, call `announceRoutingMutation()` (:634) and honor the existing `if needsEngineRebuild { return true }` abort — *before* any attach of the new sandwich (the announce-before-first-mutation contract holds). Instrument strips excluded (measured rendering fine, host no players; keeps live-thru arming cheap) — document the exclusion at the site.
3. **Comment truth** — update the `startAllPlayers` guard comment (:2666–2679) and `isPlayable` doc (:2590) to point here (the mechanism is now named; the guard stays as defense-in-depth); update `rebuildEngine`'s doc block and the m16-a note's R3 rider with a pointer.
4. **Gate script** — commit `scripts/gates/m16h-second-cycle.mjs` (adapt scratchpad `m16h-cycle.mjs`): env `PORT=`/`CYCLES=`/`STRIPS=`/`LIMITERS=`, per-cycle capture-RMS audibility + notice assertions, exit non-zero on any silent cycle or any `clip-unplayable`.
5. **m16-a gate amendment** — `scripts/gates/m16a-poison-recipe.mjs`: the `sawUnplayable > 0` PASS requirement inverts post-fix (the raise class is extinct; the dying clip plays its unlinked fd audibly). New semantics: all iterations complete + wire answers + zero wedges + zero new .ips; `clip-unplayable` becomes *permitted but not required* (sanctioned expectation replacement — the old expectation asserted the DEFECT's signature, and its extinction is the fix working; keep the wedge/crash detection unchanged, it is the gate's real job).
6. **Tests** — extend `Tests/DAWEngineTests` (EngineRebuild/Teardown suites): C7 pins below.
7. **Docs** — C11 below. No MCP/DAWControl changes (zero new commands; pins 125/128/56/69 must hold).

No full-Xcode requirement (no signing/AUv3/entitlements; SPM-buildable throughout).

## 6. GO conditions / implementer gates (C-numbered)

- **C1 (the mandate gate, amended to the true shape)**: the probe3 second-cycle recipe — 40 tone strips + 16-limiter strip, warm play, capture play — **×5 cycles in one instance, every cycle AUDIBLE by capture RMS (peak > 0.1) and ZERO `clip-unplayable`**; run the whole gate ×5 fresh instances' worth ≥ 25 audible cycles total (pre-fix: 3/3 instances fail every cycle ≥2). Then the same recipe at 2-strip scale ×5 (E4 regression).
- **C2 (gen-1 / E4b)**: fresh instance → play empty project → stop → add 2 strips while running → play → AUDIBLE, zero `clip-unplayable` (exercises Leg 2 alone).
- **C3 (daily flows stay zero-cost)**: (a) clip added to an EXISTING pre-play track after a play → audible, zero notices (the clean C2/G cell must not start announcing — pin that no rebuild is flagged via the C7 headless twin); (b) `project.open` of a played instance → audible (E7 regression).
- **C4 (mid-play birth)**: `track.add`+`clip.addAudio` DURING playback → transport resumes (playhead monotonic through the bounce), the new clip audible in its window, interruption within the m13-a C2 budget (re-measure at 41 strips; ≤300 ms).
- **C5 (m13-a matrix verbatim)**: the 2×2 {played, unplayed} × {routed, plain} `project.new` campaign ≥10 cycles + routed `track.remove` cycles + the 50-cycle discard/rebuild soak — zero crashes, `.ips` ledger byte-identical before/after; `EngineRebuildTests` green unmodified except where C7 adds.
- **C6 (m16-a poison gate ×3, amended per §5.5)**: 10/10 iterations complete, zero .ips, zero wedges; document the expectation replacement in the gate header.
- **C7 (headless pins)**: (a) strip birth on a running once-rendered engine ⇒ `needsEngineRebuild` set BEFORE any node of the new sandwich attaches, reconcile aborts (the announce-refusal idiom); (b) never-run engine strip birth attaches directly (cold path unchanged); (c) deferred rebuild: `projectWillReplace` + `tracksDidChange` with no resume/armed-thru ⇒ engine not running, `engineHasRun == false`; with resume pending ⇒ running + resumed; with an armed instrument track ⇒ running; (d) clip-onto-existing-strip while running flags NO rebuild.
- **C8 (era anchors byte-identical)**: m14c/m15a null OFF+ON, m15-f chain-null SHAs, m12-b anchors, m16-a era pin `0a6fc1c5…` — offline path untouched by construction, prove it anyway.
- **C9 (zero new RT surface)**: statement + review — both legs are main-actor control flow only.
- **C10 (suite + pins)**: full suites ≥ current baseline (2367/280 Swift + npm 118/118 at design time) + wire 125 cmds / 128 tools / catalog 56 / Explain 69 unchanged; warning-clean under forced recompile (`rtk proxy swift build` raw output).
- **C11 (docs)**: ROADMAP m16-h checkbox + annotation (the arc: m16-a A1 lead → m16-f probe3 silence → this note's standalone repro → two-leg fix); ARCHITECTURE "Key future decisions" SETTLED entry (added by this design round — keep/refine); FEATURES: no new codes (`clip-unplayable` copy stays honest — it still guards); `design-m16a-canvas-crash.md` R3 rider annotated resolved-here.

## 7. Riders (filed, not fixed here)

- **R1 — grade-B splitter**: one gen-1 configuration played audibly *while raising every pass* (E9-C3/instance D; §3.3). Under-determined; harmless post-fix (class extinct). If a future audit meets a raise-with-audio, start from the meter-tap-forces-integration suspect.
- **R2 — upstream Feedback**: the 30-line standalone (cells L/L2 vs C/N) is a clean Apple Feedback candidate: *"AVAudioPlayerNode cannot start when connected through ≥2 nodes attached to a running AVAudioEngine; public connection points report connected."* Artifacts ready in scratchpad (`avf-cells*.swift`).
- **R3 — recoverEngine watch (inherited from m13-a §6.6)**: config-change recovery still restarts the SAME engine across a stop→start boundary; unchanged here; the m13-a follow-up disposition stands.
- **R4 — RSS rider (m16-a)**: unchanged; instance A reached ~275 MB RSS after 4 heavy cycles (consistent with the known ~9.7 MB/iter under rebuild churn). Post-fix, stopped-transport storms perform *fewer* rebuilds (one per storm), which should only help; next audit still owes the clean-session baseline.
- **R5 — soak-gate audibility doctrine**: every future soak/cycle gate that plays audio MUST assert a capture/meter (this note's E1 shape). The m16-a C3 soak and the m16-f probe re-run both demonstrated that liveness-only gates certify silent sessions.

## 8. Artifacts (session scratchpad `/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/e404301f-fe34-4d54-9f9d-2afc7ee07af4/scratchpad/`)

`m16h-cycle.mjs` (the C1 gate seed), `m16h-interrogate.mjs`/`m16h-e3.mjs` (E2/E3), `m16h-e4b.mjs` (E4b/E7/E8), `m16h-e9.mjs` + `m16h-e9-replay.mjs` + `m16h-seekcheck.mjs` (E9 + grade-B verification), `m16h-e6-instrument.mjs`, `m16h-gradesplit.mjs` (E10), `avf-cells{,2,3,4,5}.swift` + `avf-cells*` binaries + `guard.o` (the standalone matrix, 19 cells), captures `m16h-*.wav` (every verdict's evidence), staging logs `m16h-staging-{a,b,c,d,f}.log` (raise counts), `m16h-ips-{before,after}.txt` (ledger). m16-f archaeology: `m16f-staging.log` (4880 raises), `m16f-analyze3.log` (the silent capture), `m16f-analyze3b.log` (the fresh-instance 61 segments).

---

## 9. Amendments (implementation round, 2026-07-13 — audio-dsp-engineer)

- **A1 — C4 interruption budget: the ≤300 ms number no longer holds for the WHOLE announce-class, and m16-h is at exact parity with it (not a regression).** Measured at 41 strips + 16 limiters, debug build, wire round-trip of the mid-play operation (probes `m16h-impl-c4*.mjs`, instance-fresh and instance-churned): mid-play strip birth (Leg 2's new announce) = **346–396 ms** (n=5, two instances); mid-play `track.addSend` — the ORIGINAL m13-a C2 recipe, a path m16-h does not touch — = **343–376 ms** (n=4, same shape). Beats-deficit interruption for the birth ≈ 415 ms (includes ~60 ms anchor lead + poll/UI-rate jitter). The class-wide growth from m13-a's measured 143 ms is a property of today's tree (master chain, PDC, notices, CC lanes, bigger strips), pre-dates this item, and applies identically to every announce-class rebuild. Every other C4 assertion PASSES: transport resumes, playhead monotonic, new clip audible in its window (window RMS 0.63), zero `clip-unplayable`, and the follow-up `clip.addAudio` onto the just-rebuilt strip stays a cheap player-only restart (66 ms deficit). **Filed as a rider for the next audit: re-baseline the announce-class rebuild budget (or optimize the rebuild) as its own item; not an m16-h condition** — Leg 2 adds zero relative cost by measurement.
- **A2 — sanctioned expectation replacement in `MasterSandwichTransparencyTests.sandwichCreationNeverAnnounces`**: the pin's post-boundary reconcile used to BIRTH strips on the running once-rendered engine and assert "no announce" — asserting the defect's enabling shape (exactly what Leg 2 now announces; the new behavior is pinned in EngineRebuildTests C7a). The sandwich-transparency target is preserved: the post-boundary pass keeps the same track identity (no birth) + a direct `ensureMasterSandwich()`, still asserting zero announces / zero rebuild debt / stable host identity. Documented at the site.
- **A3 — C6 post-fix notice shape**: the amended poison gate's runs surface `clip-envelope-skipped` (the deleted file defeats the envelope BAKE read at schedule time) while the clip itself PLAYS its unlinked fd — consistent with §5.5's prediction; recorded here so nobody mistakes that notice for the extinct raise class.
