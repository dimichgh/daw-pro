# Teardown crash root cause — stopped-engine detach of once-rendered nodes (M9 crash-a)

Fix for the crash recorded in `repro-teardown-crash.md` (played routed session → `project.new` →
next `track.add` → SIGSEGV in `AVAudioEngineGraph::UpdateGraphAfterReconfig`). Root-caused
2026-07-10 with a live instrumented repro on a debug build (control port 17696, driver
`repro-crash-a.mjs`, preserved in the session scratchpad alongside five fresh `.ips` files).

## The mechanism (proven, not conjectured)

**AVFoundation finishes a node detach's internal graph bookkeeping only when it can synchronize
with a running engine.** Detaching a node that has previously rendered while the engine is
*stopped* leaves a stale raw `AUGraphNodeBaseV3*` in `AVAudioEngineGraph`'s internal node list.
The stale entry survives `engine.reset()` and `engine.start()`. The node object is then released
by us (ARC, after we drop our dictionaries), the allocation is reused, and the **next dynamic
reconfig** — any `connect` issued while the engine is running, e.g. the first `track.add` after
`project.new` — walks the list and dereferences freed memory: `KERN_INVALID_ADDRESS`, Data Abort,
byte read translation fault, exactly the recorded stack.

Our teardown path hits this because `reconcile`'s removal loops announce
`willMutateRoutingTopology` (quiesce-then-**stop**) the moment they meet the first strip with
bus-facing wiring — so in a `project.new` pass over a routed session, the engine stops
mid-pass and every subsequent detach (in the repro: 27 nodes across 24 strips + 3 buses)
executes against a stopped-after-running engine. Every one of those is a potential stale entry;
at 41-track scale the freed memory is reliably reused and the next live connect crashes.

## Evidence matrix (all runs on the same debug build, instrumented with per-detach
`engine.isRunning` + node-address logging; logs `crash-a-app-*.log` in the session scratchpad)

| Exp | Teardown shape | Engine state at detaches | Result |
|---|---|---|---|
| A — full repro (skeleton + 16 synths + 3 buses + sends, played 3 s) ×2 | stop lands mid-pass after 1 running detach | 1 running, 27 stopped | **CRASH** at next running `connect` — stack identical to the original `.ips` (2/2, plus the original) |
| B — trivial-only session (skeleton, no sends/buses), played | no announce fires, engine never stops | all 6 strips detached **running** | survived; 5 subsequent live connects clean |
| C — no skeleton (all 16 synths non-trivial + 3 buses), played | announce fires **before any detach** | all 38 detaches **stopped** | **CRASH** — identical stack |
| D1 — A + `engine.reset()` immediately after the hook's `stop()`, before any detach | as A | stopped, reset-first | **CRASH** — `reset()` does not purge the pending state |
| D2 — A + explicit `disconnectNodeOutput`+`disconnectNodeInput` before every teardown detach | as A | stopped, disconnect-first | **CRASH** — not a zombie-connection-record problem |
| E — A with removal-triggered announces suppressed | engine never stops; whole teardown (28 strips incl. 3 buses, 17 send gains, feeders-before-buses order) runs live | all detaches **running** | survived; 5 subsequent live connects clean |

Control: every build-phase reconcile in every log (hundreds of detaches/rewires on a
**never-started** engine) is clean — the poison needs *once-rendered + stopped*, not merely
stopped.

Hypothesis verdicts against the brief's ranking:
- **H1 (teardown skips the quiesce discipline)** — held, in inverted form. The teardown *does*
  reach the quiesce-stop, but the stop is exactly what poisons the pass: the discipline is safe
  for *rewires* (attach/connect while stopped, then cold-start — the offline build order) but
  **unsafe for detaches of once-rendered nodes**. C (stop before any detach — the "cleanest"
  reading of the discipline) still crashes; B and E (no stop at all) are clean.
- **H2 (reconcile drops nodes without detach)** — refuted. The instrumented logs show every
  removed strip's nodes get paired detaches (25/25 strips in A; nothing freed while attached).
- **H3 (renderer deinit, no retire bin)** — not the trigger (the crash is main-thread, inside
  AVFoundation's connect path, not the render thread), but it leans on the same
  detach-synchronizes-with-render guarantee this fix restores: post-fix, a renderer's deinit can
  only follow a detach performed against a running engine.

## Fix design (minimal, invariants-conformant)

New Tier-boundary lifetime rule, mirroring the pointer-publish retire-bin philosophy
(ARCHITECTURE.md "three shapes"): **an AVAudioNode that may have rendered is only detached
while the engine is running; detach requests that arrive while the engine is stopped are parked
in a main-actor pending-detach bin (node stays attached and alive — no freed-memory window can
exist) and flushed right after the engine's next `start()`.**

- `PlaybackGraph.retireNode(_:)` replaces every teardown `engine.detach(...)`:
  engine running → detach now (the B/E-proven clean path); engine stopped but `engineHasRun`
  → append to `pendingDetachNodes` (bin holds the strong reference); engine never ran
  (offline builds, headless tests) → detach now, byte-identical to today.
- `PlaybackGraph.flushRetiredNodes()` drains the bin FIFO (preserves the feeders-before-buses
  edge order E validated) with the engine running. Called by AudioEngine after every successful
  `engine.start()` (prepare, the routing-rewire bounce, configuration-change recovery) and
  defensively at reconcile entry when the engine is running.
- `AudioEngine` sets `graph.engineHasRun = true` after the first successful `start()`.
- **No announce/bounce semantics change**: the engine stops and restarts exactly where it did
  before — playback, rendering and meters are untouched; only the *moment of detach* moves to
  the next running state. Binned nodes are inert across the stop window (players stopped,
  renderers unpublished, taps removed) and hold no dictionary entries.
- `detachAll()` stays dead but is routed through the same seam so any future caller cannot
  reintroduce the stopped-detach poison (perf-a's foot-gun note remains in force).

Verification plan: full live repro 3× on the fixed build + post-fix sanity (play after the
teardown, masterAnalysis level sane), plus a deterministic regression suite pinning the bin
invariant (defer-while-stopped, flush-on-running, immediate-when-never-ran) — the live crash
itself is HAL-timing dependent and not reachable headless.

## Status

Fixed 2026-07-10 (M9 crash-a). Fix: `Sources/DAWEngine/PlaybackGraph.swift` (retire seam) +
`Sources/DAWEngine/AudioEngine.swift` (flush points). Regression:
`Tests/DAWEngineTests/TeardownRetireTests.swift`.
