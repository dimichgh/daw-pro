# Teardown crash — reproduced 2026-07-10 with full stack (M9 crash-safety input)

The parked crash ("project.new after a played send/bus session → heap corruption on next track.add", original repro script lost) reproduced during the perf-c load campaign. Debug build, crash report `DAWApp-2026-07-10-161602.ips` (copy preserved in the perf-c session scratchpad; original in `~/Library/Logs/DiagnosticReports/`).

## Wire repro (exact sequence that crashed)

1. Fresh app. Build a large routed session over the control port: pop skeleton + 32 polySynth tracks with preset chains + 3 bus tracks with sends from every synth + automation lanes (the perf-c `profile-perf-c.mjs` session — 41 tracks).
2. **Play** the session (several start/stop cycles), including an offline `render.mixdown` while the live graph idles.
3. `project.new` — succeeds.
4. Next `track.add {kind:"instrument"}` — **SIGSEGV**.

## The stack (faulting thread 0, main)

```
AVAudioEngineGraph::UpdateGraphAfterReconfig(...)          ← Data Abort, byte read translation fault
AVAudioEngineGraph::_Connect(...)
AVAudioEngineImpl::Connect(...)
-[AVAudioEngine connect:to:format:]
PlaybackGraph.addInstrumentNode(for:)      PlaybackGraph.swift:1117
PlaybackGraph.reconcile(tracks:)           PlaybackGraph.swift:541
AudioEngine.tracksDidChange(_:)            AudioEngine.swift:384
ProjectStore.addTrack(name:kind:)          ProjectStore.swift:646/648 (inside performEdit)
CommandRouter.route(_:)                    Commands.swift:303
```

Register state shows AVFoundation iterating an `__NSArrayM` with a garbage element pointer (`far` = non-canonical address) — a **use-after-free of a graph node** surviving in AVFoundation's internal node list after the `project.new` teardown, dereferenced on the next graph reconfig.

## Analysis leads (join with perf-a's audit findings)

- perf-a WATCH item: **renderer deinit releases its slot object with NO retire bin** — safe only under AVFoundation's detach-synchronizes-with-render guarantee. This crash is inside AVFoundation's own bookkeeping, so the sharper suspicion is the teardown path in `PlaybackGraph`/`AudioEngine` detaching/discarding nodes in an order that leaves a stale entry in the engine's internal graph array (e.g. node released while still referenced by an engine-side connection list, or detach during an in-flight reconfig).
- perf-a WATCH item: **dead `PlaybackGraph.detachAll()`** is exactly the M4 (i) segfault shape — the teardown that *does* run on `project.new` should be compared line-by-line against why `detachAll()` was abandoned.
- The played-session precondition matters: the corruption needs the render thread to have actually run the graph (detach-while-rendered lifecycle), and the 41-track scale makes the window wide enough to hit reliably. This is the first ON-DEMAND repro: rebuild the perf-c session (script preserved), play, `project.new`, `track.add`.

## Status

**FIXED 2026-07-10 (M9 crash-a).** Root cause + evidence + fix design: `docs/research/fix-teardown-crash.md`. Mechanism: detaching once-rendered nodes while the engine is STOPPED leaves stale raw node pointers in AVFoundation's internal graph list (survives `reset()`+`start()`); the `project.new` teardown stopped the engine mid-pass (the quiesce hook), so the mass detach ran stopped and the next live `connect` walked the freed entries. Fix: `PlaybackGraph.retireNode(_:)`/`flushRetiredNodes()` — teardown detaches only execute against a running engine; stopped-window detaches park in a pending bin (nodes stay attached + alive) and retire right after the next `engine.start()`. Verified live 3× (full 41-track repro, no crash, no new `.ips`) + play-after-teardown sanity (−23 dB master while playing); deterministic regression pin in `Tests/DAWEngineTests/TeardownRetireTests.swift` (suite 1433/171 → 1437/172).
