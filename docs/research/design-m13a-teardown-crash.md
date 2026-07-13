# m13-a design — the teardown crash: root cause evidence + fix decision (engine-discard)

Date: 2026-07-12
Author: daw-architect (agent)
Status: **DESIGN SETTLED, GO-WITH-CONDITIONS** (condition C0 is a mandatory first experiment, not a formality). Implementer: audio-dsp-engineer.
Supersedes: `docs/research/audit-m13.md` §B1's "likely m12-f regression" hypothesis — **falsified below by a pre-m12-f A/B build** (audit doc carries an UPDATE marker). Extends: `docs/research/repro-teardown-crash.md`, `docs/research/fix-teardown-crash.md` (M9 crash-a).

---

## 1. Evidence (all from 2026-07-12; artifacts inventoried in §8)

Seven staging sessions on port 17695, six crashes, **one identical stack every time**:

```
AVAudioEngineGraph::UpdateGraphAfterReconfig   ← KERN_INVALID_ADDRESS (garbage node ptr)
AVAudioEngineGraph::RemoveNode
-[AVAudioEngine detachNode:]
PlaybackGraph.flushRetiredNodes()              PlaybackGraph.swift:412 (HEAD build: 406)
AudioEngine.tracksDidChange(_:)                AudioEngine.swift:471  ← the engineStoppedForRoutingRewire branch
<ProjectStore.newProject:3098 | ProjectStore.removeTrack>  ← via CommandRouter
```

| # | Binary | Trigger | Session at trigger | Result | .ips |
|---|---|---|---|---|---|
| 1 | current (dist-#21-era src) | `project.new` | out→busA + send→busB, played 1.2 s, stopped | CRASH | `095344` |
| 2 | current | `project.new` (final routed recipe of a longer script; timeline-attributed §2.3) | routed, played, stopped | CRASH | `095622` |
| 3 | current | `project.new`, ~1.3 s into a fresh instance | reconstruction says plain/near-empty — **ANOMALY, unresolved (§2.4)** | CRASH | `095844` |
| 5 | current | stepwise `cycle.mjs`: empty ✓, plain ×4 ✓, instrument ×2 ✓, **played-plain ×2 ✓**, routed #1 ✗ | routed, played, stopped | CRASH at routed #1 | `101841` |
| 6 | **pre-m12-f** (git-worktree build of HEAD `0ad2e51`) | same `cycle.mjs`: identical pattern — everything survives, **routed #1 ✗** | routed, played, stopped | CRASH, same stack (era-shifted lines: flush at 406, newProject at 2944) | `102257` |
| 7 | current | **`track.remove` of the routed source — NO `project.new` involved** (`cycle2.mjs`) | routed, played, stopped | CRASH at removal #1 | `102430` |

Baseline validity of session 6: HEAD (`0ad2e51`, 2026-07-11 18:30) hashes **byte-identical to the orchestrator's m12c-era pin** (`scratchpad/m12c-rt-orch.sha`) on all five pinned sidechain files (`ChainHostAU/EffectChainProcessor/Compressor/Gate/EffectRendering`), and `/usr/bin/diff` of HEAD-vs-current `PlaybackGraph.swift` contains **exclusively m12-f sidechain hunks** (+121/−12, every hunk key-edge/PDC-key/2-bus tagged; zero tempo hunks — full diff preserved as `playbackgraph-m12f.diff`). So HEAD is the authentic pre-m12-f engine for this purpose.

OS constant across eras: every `.ips` from 2026-07-10 AND 2026-07-12 reports **macOS 26.4 (25E246)** — no OS-update explanation.

## 2. What we know, and what we don't

### 2.1 KNOWN (proven)
1. **Not an m12-f regression.** The pre-m12-f binary crashes identically, first routed cycle (session 6). m12-f's PlaybackGraph changes (2-bus ChainHostAU main-feed `toBus:0` connect at `PlaybackGraph.swift:1264-1272`, key fan-out points `:727-745`, announce widening via `oldKeyInvolvedStrips` `:488-494,530-533`, `setKeyConnected` flags `:760-775`) are all **inert in the repro** (no keys configured) and exonerated.
2. **The M9 crash-a fix's safety premise is falsified.** The fix (`fix-teardown-crash.md:55-77`) rests on "an AVAudioNode that may have rendered is only detached while the engine is running." Every crash above IS a detach against a running engine — `flushRetiredNodes` guards on `engine.isRunning` (`PlaybackGraph.swift:409-415`) and runs right after `engine.reset()` + `engine.start()` (`AudioEngine.swift:457-472`). The refined poison model: **"running at detach time" is not sufficient — nodes that sat attached across a stop→reset→start boundary after having rendered are already poisoned in AVFoundation's internal node vector**, and the post-restart detach walks the stale entry. This is consistent with M9's own D1 experiment (`reset()` does not purge pending state, `fix-teardown-crash.md:34`) and with B/E only ever testing detaches against a *continuously* running engine (`:31-36`).
3. **The class covers both whole-project teardown AND in-session routed `track.remove`** (session 7) — any announce-class teardown (quiesce-stop → retire-while-stopped → restart → flush-detach) after the engine has rendered. Trigger determinism today: routed teardown = 4/4 first-attempt crashes across two binaries (sessions 1, 5, 6, 7; session 2 timeline-consistent).
4. **Plain teardowns are currently surviving** (session 5: empty/plain/instrument/played-plain = 9 consecutive clean `project.new`s) — they never announce (`isTrivial` check `PlaybackGraph.swift:502-508`), so the engine never stops mid-pass and detaches run against the continuously-running engine (the M9 B/E-proven clean shape).

### 2.2 UNKNOWN (recorded honestly)
- **Why the M9 verification passed 3× on 2026-07-10** (41-track repro, `repro-teardown-crash.md:36`) while today a 3-track recipe kills both binaries on attempt 1. The 07-10 source is unavailable (no commit, no pin); same OS; intervening `PlaybackGraph`/`AudioEngine` changes in the window (m10-n instrument reload, m12-b's 20-row tempo refactor of this file) cannot be diffed. **The fix must not depend on resolving this** — but C0 (§7) will likely reveal it.
- **Session 3's flag source.** Its `.ips` proves the `engineStoppedForRoutingRewire` branch ran (frame at `AudioEngine.swift:471`), but the reconstructed session (near-empty, unplayed, unrouted, ~1.3 s old) has no announce-capable wiring, and session 5 explicitly survived that exact shape. Either the reconstruction is wrong (command in flight mis-attributed) or a **second flag-setting window exists**. The `recoverEngine` path also flushes (`AudioEngine.swift:1403`) but sets no flag — it does not explain frame :471.

### 2.3 Session-2 attribution
Probe2 run #1 ends with the routed recipe (build → play 1.2 s → stop → `project.new`); its ~25 s runtime from a ~09:55:55 start lands exactly on the 09:56:22 crash capture. Session 2 is therefore attributed to the routed mechanism, not to a plain teardown.

### 2.4 C0 — the mandatory discriminating experiment (run FIRST, before any fix code)
Reproduce the M9 evidence-matrix method (`fix-teardown-crash.md:26-40`): stderr-instrument (a) every `announceRoutingMutation()` call **with the reason branch and trackID**, (b) every `retireNode` with node address + `engine.isRunning`, (c) `flushRetiredNodes` entry with bin contents, (d) the hook itself. Then run: (i) `cycle.mjs` (crashes at routed #1 — confirms the mechanism narrative and shows exactly which node's detach dies), (ii) fresh-launch → immediate `project.new` ×20 (the session-3 shape — resolves the anomaly or retires it as mis-attribution), (iii) `cycle2.mjs`. Deliverable: a table like M9's. This is ~an hour against a deterministic repro and de-risks the entire item.

## 3. The decision

**Retire per-node detach for once-rendered engines entirely. Teardown = discard the whole `AVAudioEngine` and rebuild from the model.**

- **A1 (unconditional): project boundaries** — `project.new` / `project.open` discard the engine + graph objects wholesale and build fresh. No detach of a once-rendered node can occur, by construction. There is no warm state worth keeping at a project boundary — the session is being replaced anyway.
- **A2 (primary): in-session announce-class rewires** — the same discard-and-rebuild replaces the quiesce-stop → retire → reset/start → flush sequence in `tracksDidChange`. ONE teardown mechanism everywhere; the announce path already interrupts playback with a documented audible bounce (m12-f measured today's bounce at 36 ms), and resume machinery exists (`resumeAfterRoutingRewire`, `AudioEngine.swift:495-514`).

**Why this wins:** the offline renderer already builds a fresh engine per render, and M9's own control observation is that *"every build-phase reconcile … on a never-started engine is clean"* (`fix-teardown-crash.md:38-40`) — fresh-build is the one path with a two-day-old, hundreds-of-detaches-scale proof. We have now falsified **two successive surgical models** of AVFoundation's private bookkeeping ("detach while running is safe" — M9; "flush right after restart is safe" — today). A third surgical model would be built on the same opaque foundation.

### Alternatives and why they lose
1. **(B) Two-phase reconcile surgery** — detach all removals FIRST against the continuously-running engine (M9 experiment E's clean shape), THEN stop for adds/rewires. Loses as primary: it is a third bet on an undocumented invariant ("continuously-running detach is safe" — proven in exactly one instrumented session on one build), keeps the retire/flush machinery alive, and leaves the class one refactor away from returning. **Recorded as the fallback** if A2's measured rebuild cost exceeds budget (§7 C2) — B's shape is compatible with the same gate.
2. **(C) Never-detach node parking** — disconnect and pool once-rendered nodes forever, reuse on rebuild. Loses: unbounded node growth across an editing session (AVAudioEngine bus-count and node-count pressure), still exercises disconnect paths through the same bookkeeping, and is strictly more complex than discarding the engine.
3. **(A1-only hybrid, B for in-session)** — rejected because session 7 proves the in-session leg is exactly where the poison lives; fixing only boundaries leaves a daily-driver crash (`track.remove` of a routed track).

## 4. Rebuild inventory (what A must recreate vs what survives)

**Must rebuild (all main-actor, all existing cold-build code paths):** per-clip `AVAudioPlayerNode`s + schedules (existing `scheduleAll`/restart primitive), per-strip mixer/sumMixer/`ChainHostAU` sandwiches (`PlaybackGraph.swift:1259-1280`), send-gain nodes + fan-out points, instrument `AVAudioSourceNode`s (+ schedule republish via the existing reschedule machinery; flush semantics unchanged), bus sandwiches, metronome attach (`AudioEngine.swift:313`), master meter tap (`:310`) + per-track taps + masterAnalysis tap, performance-counter contexts, PDC rings (recompute — pure), MIDI-thru fanout re-sync (`syncMIDIThruFanout`), `engineHasRun`/watchdog reset.

**Survives untouched (the load-bearing good news):** every `EffectChainProcessor` + its effect instances **including hosted-AU effects and their state** — chains are OUR objects published to the new `ChainHostAU` host via the existing rebind (`ChainHostAU.chainProcessor(of:)` seam, `PlaybackGraph.swift:1273-1275`); `AUHostRegistry` prepared **instruments** (never engine citizens — driven by our scheduler through `InstrumentRendering`, ARCHITECTURE sequencer-clock entry); the input-capture engine (a separate `AVAudioEngine` by design — ARCHITECTURE "Input capture"); all DAWCore state; the control server; UI observation.

**Deleted when done:** `retireNode` / `flushRetiredNodes` / `pendingDetachNodes` / `engineStoppedForRoutingRewire` + the flush call sites (`PlaybackGraph.swift:376-415`, `AudioEngine.swift:457-472,1401-1403`); `detachAll()` stays dead and now unreachable.

## 5. RT-safety statement

Zero render-thread changes. Discard happens on the main actor against a stopped engine; `AVAudioEngine` deallocation is the framework's own whole-object teardown path (C1 spikes it 50×). The atomic-publish effect chains, instrument schedule pointers, and meter taps follow the same publish/unpublish discipline they use across today's stop/start bounce — no new allocation, locking, or ObjC dispatch on the render path. The one watch item: releasing the old engine must happen AFTER `stop()` returns (render callbacks quiesced by the framework), which is the ordinary dealloc contract.

## 6. Implementation plan

1. **C0 experiment** (§2.4) — table of announce/retire/flush events for the three recipes; resolves §2.2. STOP and re-design if C0 shows detaches crashing on the *continuously-running* path too (would falsify B as fallback and demand A everywhere including config-change recovery).
2. `Sources/DAWEngine/AudioEngine.swift` — new `rebuildEngine(reason:)` primitive: capture resume state (the existing `resumeAfterRoutingRewire` shape), `engine.stop()`, drop `graph`, release `engine`, create fresh `AVAudioEngine` + `PlaybackGraph`, re-run the `prepare()` build sequence + full `reconcile(tracks:)` from the model, reinstall taps/metronome/hooks (extract the `init` hook wiring into a reusable `wireGraphHooks()`), resume via `startPlayers(renderClockTrusted: false)`.
3. `Sources/DAWEngine/AudioEngine.swift` — `tracksDidChange`: replace the `engineStoppedForRoutingRewire` consume branch with `rebuildEngine` when the graph announced; `willMutateRoutingTopology` hook shrinks to "wind down transport + set needsRebuild" (no `engine.stop()` mid-pass — the rebuild stops it).
4. `ProjectStore.newProject`/`openProject` (`Sources/DAWCore/ProjectStore.swift:3098,3059`) — no store change needed if the engine seam handles it; otherwise add an explicit `engine?.projectWillReplace()` intent for A1 (decide in implementation; keep ProjectStore engine-agnostic).
5. `Sources/DAWEngine/PlaybackGraph.swift` — delete the retire bin (§4); reconcile keeps its structure but teardown branches detach ONLY when the engine has never run (headless/offline) — all other teardown is unreachable (rebuild replaces it).
6. Config-change recovery (`recoverEngine`, `AudioEngine.swift:1380-1407`) — OUT OF SCOPE for m13-a except: its `flushRetiredNodes()` call dies with the bin. If C0 implicates it, file a follow-up rather than swelling this item.
7. Tests — `Tests/DAWEngineTests/TeardownRetireTests.swift` is superseded: replace with `EngineRebuildTests` (headless: rebuild preserves chain-processor identity, instrument descriptors, PDC recompute; never-ran engines still detach directly). Offline-render byte gates unchanged (offline path untouched — it already builds fresh engines).

## 7. GO conditions + implementer gate (verbatim-ready, expands ROADMAP m13-a)

- **C0** — the §2.4 instrumented evidence table, committed to the fix PR/report. Must name which node's detach faults in `cycle.mjs` and resolve or formally retire the session-3 anomaly.
- **C1 (spike)** — 50× discard/rebuild cycles with real renders between (play ≥ 0.5 s each), RSS growth bounded (< 20 MB drift over the run), zero new `.ips`.
- **C2 (budget)** — measured rebuild wall time at 3-track and 41-track scale; budget ≤ 300 ms at 41 tracks (today's bounce is 36 ms; the design accepts a slower but bounded interruption on an already-interrupting path). Over budget ⇒ fall back to B (two-phase reconcile) for in-session rewires, keep A1 for boundaries, and re-gate.
- **C3 (crash campaign)** — all clean, with the `.ips`-zero assertion procedure: `ls -1 ~/Library/Logs/DiagnosticReports/DAWApp*.ips | sort` **before and after each block** (byte-equal listings; also check `Retired/`), app pids tracked via `pgrep -x DAWApp`:
  1. The historical 41-track perf-c repro ×3 (build, play cycles + offline render, `project.new`, `track.add`, play).
  2. This audit's scripts verbatim: `cycle.mjs` (must now log `ALL CYCLES SURVIVED`), `cycle2.mjs` (routed removals ×3 + post-removal play), `probe2.mjs`-shaped end-to-end (sidechain key set/remove/undo then routed recipe).
  3. **N ≥ 10 `project.new` cycling campaign** across the 2×2 matrix {played, unplayed} × {routed (out+send+bus), plain}, fresh app, zero crashes.
  4. Fresh-launch → immediate `project.new` ×20 (session-3 shape).
- **C4 (behavior held)** — null gates: offline mixdown of the m12-b anchor project byte-identical (offline path untouched); live: mid-play send-add still meters on its bus (the M4-i contract) through the new rebuild path; metronome/click and MIDI-thru function after a rebuild; plugin windows survive or close-and-reopen cleanly across rebuild (ledger invalidation via the existing `onRelease` seam — verify, decide, document).
- **C5 (docs)** — ROADMAP `## Blocked` teardown entry rewritten with the full arc (2026-07-06 discovery → M9 crash-a fix → 2026-07-12 falsification, sessions + `.ips` ids → engine-discard resolution); ARCHITECTURE.md "Key future decisions" gains the SETTLED entry: *"Engine lifecycle: once-rendered engines are never surgically detached; teardown-class changes discard and rebuild the engine (m13-a)."* `fix-teardown-crash.md` gets a status update pointing here.

## 8. Artifacts (session scratchpad `m13-audit/`)

`cycle.mjs` (stepwise teardown matrix), `cycle2.mjs` (routed removals), `probe.mjs`/`probe2.mjs`/`probe3.mjs` (audit probes), six `.ips` copies (`095344`, `095622`, `095844`, `101841`, `102257` [pre-m12-f binary], `102430` [track.remove]), `playbackgraph-m12f.diff` (HEAD→current, the exonerating diff), `PlaybackGraph.HEAD.swift`. Pre-m12-f binary recipe: `git worktree add <dir> HEAD && cd <dir> && swift build --product DAWApp` (worktree used for session 6 has been removed from the repo; HEAD `0ad2e51` hash-validated against `m12c-rt-orch.sha` on all five shared files). Staging law respected throughout: port 17695 only, `pgrep -x`/`kill` teardown, `session.lock` cleared.

No full-Xcode requirement anywhere in this item (no signing, no AUv3 packaging; all engine work is SPM-buildable).
