# Render-Thread Safety Audit (M9 perf-a)

Date: 2026-07-10. Auditor: audio-dsp-engineer. Scope: `Sources/DAWEngine` + `Sources/CAtomics` — every site that runs on, or synchronously feeds, the render thread, plus the relaxed-tier tap/queue-side code. Method: grep-driven sweep for risky constructs (`DispatchQueue`, locks, `Task {`, `await`, allocation idioms, logging, `daw_atomic*` call sites), then a line-level read of every render-reachable function.

## Rules audited

**Tier 1 — render thread (strict).** Applies to the AVAudioSourceNode render block, `ChainHostAU.internalRenderBlock`, everything they synchronously call, and the CoreMIDI receive block (CoreMIDI realtime thread — same rules by house doctrine). No heap allocation, no locks/semaphores, no Swift actor hops or `Task` creation, no ObjC dynamic-dispatch machinery beyond the AVFoundation/CoreMIDI callback entry itself, no file I/O, no unbounded loops, no ObjC exceptions. Allowed: preallocated buffers, C atomics (`CAtomics`), pure math (libm included), bounded loops over preallocated storage, Swift protocol witness dispatch, calls into an AU's captured `renderBlock`/`scheduleMIDIEventBlock`.

**Tier 2 — tap/dispatch-queue side (relaxed).** AVFoundation tap closures (master meter, per-track/bus meters, input capture), notification blocks, and the writer's private serial queue run on their own dispatch queues, never the render thread. Allocation is tolerated but must be minimal, deliberate, and documented (precedent: `MasterMixAnalyzer.snapshot()`'s single bands-array allocation). The established publish idiom is: compute scalars in the tap, hop to the main actor with one `Task { @MainActor }` carrying a Sendable value.

Verdicts: **SAFE** (obeys its tier), **VIOLATION** (breaks its tier — would be fixed this cycle), **WATCH** (technically tolerable but fragile — reason given).

## Inventory

### Family 1 — source-node / render callbacks (Tier 1)

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `InstrumentSourceNode.swift:166` source-node block → `renderQuantum` (:178–369) | render thread | SAFE | Flush/dropped flags via `daw_atomic_u32_exchange`; schedule borrowed `takeUnretainedValue` (retire bin guarantees lifetime); event slice via `UnsafeBufferPointer(rebasing:)` — no Array machinery; live-event drain into preallocated `liveScratch`/`mergedScratch`; host-tick math uses `ticksToSeconds` precomputed in init (no `mach_timebase_info` syscall); overflow policy leaves live events queued, never allocates. |
| `MIDISchedule.swift:25–54` `MIDIEventSchedule` storage | built main actor, read render thread | SAFE | Events live in manually allocated memory (`UnsafeMutableBufferPointer.allocate` in init, freed in deinit); immutable after publish; `buildEvents` is main-actor-only. |
| `Instruments/TestToneInstrument.swift:45` `render` | render thread | SAFE | Fixed 16-voice heap block from init; pure sine math; `memset`/`memcpy` only. |
| `Instruments/PolySynthInstrument.swift:149` `render` (+ :158 param adopt, :284 `recomputeCoefficients`) | render thread | SAFE | Param snapshot borrowed via atomic slot; coefficients recomputed per generation only (pure libm); per-quantum NaN kill + denormal flush on SVF state; voices in fixed heap block. |
| `Instruments/SamplerInstrument.swift:257` `render` | render thread | SAFE | Zone audio fully loaded in init (main actor) into immutable buffers; render is interpolated reads + linear envelopes; NaN guard per quantum; `output.dropFirst(2)` is a non-allocating Slice. |
| `Instruments/EventCaptureInstrument.swift:54` `render` | render thread (offline pulls in tests) | SAFE | Test vehicle; appends PODs into a preallocated 16 384-slot ring via single-writer atomic index. |
| `AudioUnits/SilentPlaceholderInstrument.swift:11` `render` | render thread | SAFE | `memset` zeros only. |
| `AudioUnits/HostedAUInstrument.swift:112` `render`, :180 `reset` | render thread | SAFE | Touches only the two blocks captured at init (`renderBlock`, `scheduleMIDIEventBlock`) + preallocated shadow ABL / 3-byte MIDI buffer / atomic error slot; render failure = memset silence + error breadcrumb atomic, no logging; `reset()` = CC 123/120 through the schedule block, never `AUAudioUnit.reset()`. |
| `Effects/ChainHostAU.swift:124–175` `internalRenderBlock` | render thread | SAFE | Captures processor/automation/compensation/scratch — never `self`, so no ObjC property surface reachable; scratch fallback preallocated in `allocateRenderResources`. |
| `Effects/EffectChainProcessor.swift:149` `process` | render thread | SAFE | Snapshot borrowed via atomic slot; `ContiguousArray.withUnsafeBufferPointer` walk; bypass/reset are u32 atomics on stable heap addresses. |
| Built-in effect `process()` + `storeAutomatedParam()`: `GainEffect:143`, `EQEffect:209`, `CompressorEffect:168`, `LimiterEffect:193`, `ReverbEffect` (~:200), `DelayEffect:171`, `SaturatorEffect:139`, `GateEffect:161`, `ChorusEffect:185` | render thread | SAFE | Uniform pattern verified per kind: preallocated lines/state (MAX-sized so automated params never resize), `InlineChannelPointers` fixed stack storage for the pointer gather, `AutomationParamOverlay` by-value POD, derive math is pure libm, denormal flushes on all recursive state, main-actor `apply()` owns the only allocations (snapshot box + retire bin). |
| `Effects/HostedAUEffect.swift:148` `process` | render thread | SAFE | Pull block reads a stash box set/cleared inside the same synchronous render; renders into preallocated scratch ABL; failure = dry passthrough + atomic breadcrumb. |
| `Effects/HostedAUEffect.swift:196` `reset()` → `auAudioUnit.reset()` | render thread | **WATCH** | One sanctioned ObjC message on the render thread (M4 v design decision: effects have no MIDI all-notes-off; `AudioUnitReset` is the only tail-clear). Fires only at reset edges (stop / un-bypass), never per quantum. Fragile if reset semantics ever become per-quantum — keep edge-triggered. |
| `Effects/CompensationDelay.swift:134` `process` | render thread | SAFE | Ring storage main-thread (de)allocated only inside `allocateRenderResources`/`deallocateRenderResources` (host guarantees no concurrent render — reliance noted in WATCH list); render side is atomic target/reset loads + mask-indexed ring math; bit-exact inert fast path. |
| `Automation/AutomationRenderer.swift:108` `apply`, :156 `storeEffectParams` | render thread | SAFE | Schedule borrowed via atomic slot; preallocated cursor block (`maxEffectParamTracks` hard cap matches the build cap); bounded binary-search re-seek; gain/pan stages are pure per-sample math with unity/center bit-exact skips. |
| `Automation/AutomationSchedule.swift:192–227` `seek`/`value` | render thread (pure) | SAFE | Reads owned `UnsafeBufferPointer` breakpoint storage (allocated init / freed deinit); build/resolve are main-actor-only. |
| Player scheduling: `PlaybackGraph.scheduleAll` (:1242–1381), `Metronome` (all), `AudioEngine.startTestTone` (:1280) | main actor | SAFE | `scheduleSegment`/`scheduleBuffer`/fade-bake file reads are control-plane; AVFoundation owns the RT hand-off. Completion handlers deliberately nil everywhere (comment-pinned). Click/tone buffers synthesized once per rate. |

### Family 2 — tap closures (Tier 2)

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `AudioEngine.swift:1323–1356` master meter tap (+ `MasterMixAnalyzer.processMix`/`snapshot` ride-along) | AVFAudio serial tap queue | SAFE | Scalar peak/RMS loop; analyzer fed in place; the one per-buffer `Task { @MainActor }` hop is the documented Tier-2 idiom; no engine state touched in the closure; `@Sendable` load-bearing (comment-pinned). |
| `PlaybackGraph.swift:1209–1233` per-track/bus meter tap | tap queue (or synchronously inside offline pulls) | SAFE | Same idiom; captures self strongly in the hop by design (offline frames must deliver after return); trackID captured by value. |
| `InputCapture.swift:118–120` input tap | input engine's tap queue | SAFE | Captures only the writer; hands the tap-owned buffer across via one enqueue — file I/O never happens here (family 6). |
| `AudioEngine.swift:231–239`, `InputCapture.swift:133–143` config-change notification blocks; `AudioEngine.swift:804` record-permission callback | arbitrary non-main threads | SAFE | Hop-only bodies (`Task { @MainActor }`), nothing else touched. |

### Family 3 — MIDI scheduling & CoreMIDI callbacks

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `MIDIInputManager.swift:203–207` receive block → `MIDIInputRTContext.receive` (:92–137) | CoreMIDI realtime receive thread (Tier 1) | SAFE | Pointer-math packet walk with whole-message stride; pure `MIDIUMPParser`; `mach_absolute_time()` fallback (not a syscall); fanout borrowed via atomic slot without retain (strong refs pinned by the published `LiveEventFanout`); struct offsets precomputed in init so no key-path machinery on the RT thread. |
| `MIDIInputRTContext.deliver` counters (:133–136) | receive thread | **WATCH** | `eventCounter`/`overflowCounter` increment via non-atomic load→store RMW — correct ONLY under the documented single-producer rule (one UMP port). Creating a second input port would silently corrupt counts. |
| `LiveEventRing.swift:59–79` `push`/`pop` | producer: receive thread; consumer: render thread (thru) or main actor (capture) | SAFE | SPSC with free-running u32 counters; orders verified: slot write → release-store head; acquire-load head → slot read → release-store tail. Drop-newest + dropped flag; render side answers with `instrument.reset()` so a lost note-off can't stick a voice. |
| Thru drain: `InstrumentSourceNode.swift:254–282` | render thread | SAFE | Pops into preallocated scratch; live noteID map is a fixed 128-slot block; merge is a single-split stable copy into preallocated storage. |
| Schedule walk during playback | render thread (`renderQuantum` step 5) | SAFE | The only walker of `MIDIEventSchedule.events` is the render quantum itself — immutable, preallocated, cursor-monotonic. |
| `MIDIInputManager.swift:191–196` notify block | CoreMIDI thread | SAFE | Hop-only. Enumeration/reconnect (`setupChanged`) is main-actor. |
| Capture drain + `MIDICaptureSession` (:283–303; MIDICaptureSession.swift) | main actor (~30 Hz) | SAFE | Ring consumer on the main actor; note pairing/clamping is pure main-actor code. |
| Fanout publish (:267–277) | main actor | SAFE | passRetained slot exchange + ≥ 1 s retire bin, the standard pattern. |

### Family 4 — MasterMixAnalyzer (vm-a re-verification)

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `Analysis/MasterMixAnalyzer.swift:138–212` init | main actor (tap install) | SAFE | ALL buffers (`hann/fifo/windowed/real/imag/magnitudes/previous/scratch/power/binFrequencies/monoScratch`) allocated here; band→bin tables computed here; vDSP FFT setup here. Preallocation contract intact. |
| :232–284 `process`/`processMix` | tap queue | SAFE | Verified allocation-free: FIFO copy, vDSP calls on preallocated storage, bounded mono-mix chunks (4096); poisoned frames skipped whole; denormal flushes on all smoothed state. Private Swift-array state (`smoothedBandPower` etc.) is written element-wise while uniquely referenced — no CoW possible as nothing escapes. |
| :290–303 `snapshot()` | tap queue | SAFE | The one documented Tier-2 allocation (24-element `bands` array + snapshot value), matching the meter tap's `MeterFrame`+`Task` idiom. Exception stands, unchanged. |
| :307–317 `reset()` | main actor, engine stopped | SAFE | Called only from `shutdown()` AFTER tap removal + engine stop (`AudioEngine.swift:279–290`) — honors its threading contract. |

### Family 5 — stretch bridging (CSignalsmithStretch)

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `Stretch/OfflineStretcher.swift` | detached worker task only | SAFE | Header contract: "Never call on the render thread: it allocates freely." Sole caller is `StretchRenderCache`'s render job. |
| `Stretch/StretchRenderCache.swift:179–231` job model | main actor + `Task.detached` worker | SAFE | All file I/O and C-shim processing on the worker; atomic-rename commit; the live path only swaps a clip's FILE URL at reconcile (`PlaybackGraph.swift:461–467`) — the render thread never sees the stretch engine. |

### Family 6 — recording writer path

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `RecordingWriter.swift:173–184` `append` | input tap queue | SAFE / see WATCH | Sets the lock-backed first-buffer flag, wraps the tap-owned buffer in a `@unchecked Sendable` POD, enqueues onto the private serial queue. No file I/O here. |
| `RecordingWriter.swift:39` + :231–399 queue internals | private serial `DispatchQueue` | SAFE | ALL file I/O (open/write/finalize/delete) is queue-confined; scratch buffer reused (grow-only); per-write `autoreleasepool` bounds ObjC autorelease traffic; stderr notes are queue-side, never tap-side beyond the enqueue. |
| `RecordingWriter.swift:51` `OSAllocatedUnfairLock` `receivedAudio` | tap queue writer / main-actor reader | **WATCH** | A lock taken on every tap delivery. Legal on Tier 2 (uncontended, two instructions) and needed for the watchdog's cross-thread read — but this exact pattern would be a VIOLATION if copied into a render callback. Keep it out of Tier 1. |
| Watchdog + finalize completion (`AudioEngine.swift:948–958`, :1020–1039) | main actor / writer queue → main hop | SAFE | Task.sleep watchdog; completions hop with `Task { @MainActor }`. |

### Family 7 — atomics usage (CAtomics)

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| `CAtomics/include/CAtomics.h` | — | SAFE | Loads = acquire, stores = release, exchanges = acq_rel — correct for every usage pattern in the repo (pointer publish/borrow, set-and-consume flags, SPSC counters). Header mandates heap allocation for stable addresses; verified every call site uses `UnsafeMutablePointer.allocate` (never `&property`). |
| Pointer-publish slots (schedule/params/chain/automation/fanout) | main-actor `passRetained` exchange; RT `takeUnretainedValue` borrow | SAFE | Uniform invariant: slot holds +1; displaced object → main-actor retire bin, released only when > 1 s old; render side never retains, never performs a last release. See WATCH note on the ARC subtlety. |
| Consume-once flags (`flushFlag`, `droppedFlag`, `resetFlag`, PDC `resetFlag`) | main-actor store-release; RT exchange-acq_rel | SAFE | Exchange-consume semantics — a flag can never be lost or double-honored. |
| PDC `target` u32 | main-actor store; RT load each quantum | SAFE | Single scalar; clamped at store AND load; retarget declicks render-side. |
| Free-running SPSC counters (`LiveEventRing.head/tail`) | one writer each side | SAFE | Wrapping arithmetic; full/empty never alias; ordering verified (family 3). |
| Monotonic event/overflow counters | receive thread only | **WATCH** | See family 3 — single-writer load→store RMW. |
| Torn-read review | — | SAFE | Every cross-thread value is a ≤ 64-bit atomic or an immutable heap object published by pointer; no multi-word state is read unsynchronized anywhere on the render path. |

### Family 8 — reachability sweep (locks/dispatch/Task/alloc idioms)

| Site | Thread/queue | Verdict | Rationale |
|---|---|---|---|
| Logging | — | SAFE | Zero `print`/`os_log`/`NSLog`/`Logger` in DAWEngine. Every `FileHandle.standardError.write` sits on main-actor/reconcile/worker/writer-queue paths (each grep hit read and placed). |
| `Task {` / `await` / `DispatchQueue` sites | — | SAFE | Every one enumerated: main-actor jobs (AU prepare, stretch/transient caches, playhead, drain, watchdog), Tier-2 tap hops, or the writer's serial queue. None reachable from Tier 1. |
| `ContinuousClock.now` / `Date()` | — | SAFE | Only in main-actor publish methods (retire bins). Render paths use precomputed `ticksToSeconds`; `mach_timebase_info` never called after init. |
| Allocation idioms (`Array(`, `.append(`, `map`, string interpolation) in render-adjacent files | — | SAFE | All hits are main-actor publish/retire/init/bake paths. Render paths use `UnsafeBufferPointer` slices, fixed stack structs, and preallocated blocks throughout. |
| `PlaybackGraph.detachAll()` (:1493) | main actor — **zero callers** | **WATCH** | Dead code. Unlike `reconcile`, it detaches bus-facing wiring WITHOUT announcing `willMutateRoutingTopology`; wiring it into any live-engine teardown path would reintroduce the measured M4 (i) render-thread segfault class. Either delete it or give it the announce discipline before first use. |
| Reconcile / rewire boundary discipline | main actor | SAFE | `willMutateRoutingTopology` fires before the FIRST routing mutation of a pass; the live engine leaves the running state first (quiescence-then-stop), so no rewire ever mutates under an active render. In-place paths (send level, clip gain, chain publish, PDC target, param snapshots) are all atomic/property writes by construction. |
| `MainActor.assumeIsolated` in `HostedAUInstrument/Effect.prepare` | main actor today | SAFE | All `prepare` call sites are main-actor (strip build / chain sync). If the contract ever drifts, `assumeIsolated` traps loudly instead of corrupting — acceptable guard. |

## Findings summary

- **Sites audited: 47 rows across 8 families** (Tier 1: 17, Tier 2: 8, MIDI: 8, analyzer: 4, stretch: 2, recording: 4, atomics: 7 patterns, sweep: 7 — some rows cover a uniform multi-file pattern, e.g. the nine built-in effects).
- **Violations: 0.** No render-thread heap allocation, lock, actor hop, Task creation, file I/O, unbounded loop, or logging was found on any Tier-1 path. Tier-2 code stays within the documented idioms.
- **Fixes applied: 0** (nothing to fix; behavior byte-identical by construction).
- **Watch list (6):**
  1. `HostedAUEffect.reset()` — sanctioned ObjC `auAudioUnit.reset()` on the render thread, edge-triggered only; must never become per-quantum.
  2. `RecordingWriter.receivedAudio` unfair lock — fine on the input tap queue; the pattern must never migrate into a render callback.
  3. `MIDIInputRTContext` counters — non-atomic RMW valid only while there is exactly ONE input port (single producer).
  4. `CompensationDelayState.allocate/release` — relies on the host's no-render-during-`(de)allocateRenderResources` guarantee; calling `release()` outside that window would race `process()`.
  5. The `takeUnretainedValue` borrow pattern — ARC may still emit retain/release around the borrowed reference (lock-free, non-allocating; safe because the retire bin + slot retain make a render-thread LAST release impossible). Every new publish site must copy the slot + retire-bin pattern exactly.
  6. `PlaybackGraph.detachAll()` — dead code that bypasses the routing-rewire announce; delete or fix before first use.

## Teardown-crash observations (out of scope, notes only)

The parked `project.new`-after-played-send/bus-session crash was not reproduced or fixed here, but the audit surfaced two mechanisms worth handing to the M9 crash-safety cycle:

1. `PlaybackGraph.detachAll()` detaches send-gain and bus wiring without firing `willMutateRoutingTopology` — the exact class measured to segfault the render thread when done against a running engine. It has no callers today, so it is not the live crash — but any teardown path added for `project.new` that reaches for it (or replicates its shape) would crash exactly this way.
2. Teardown lifetime: a renderer/processor `deinit` releases its slot's retained object IMMEDIATELY (no retire bin) — safe only because deinit implies the owning source node (whose render block retains the renderer via `[self]`) is already detached, i.e. correctness leans on AVFoundation's detach-synchronizes-with-render guarantee. If the crash backtrace shows a render callback racing node detach during the `project.new` reconcile, this ordering is where to look first.

## Codification

The invariants above are codified in `docs/ARCHITECTURE.md` § "RT-safety invariants" (added this cycle) — that section, not this audit, is the normative reference for future engine reviews.
