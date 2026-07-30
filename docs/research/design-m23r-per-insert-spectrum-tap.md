# m23-r — Per-insert spectrum tap: design + sub-item split

**Author:** daw-architect · **Date:** 2026-07-27 · **Status:** DESIGN ACCEPTED for split; no code written.
**Supersedes:** `docs/research/design-m22b-eq-curve-editor.md` §4.3 (:323-358).
**Orchestrator note:** the three load-bearing claims (C1 hook point, C3 offline isolation, and the
null-pin vacuity finding) were independently re-measured by the orch pass before acceptance — see §7.

---

## 0. Headline

§4.3's *cost argument* is confirmed. §4.3's *architecture* is corrected on one load-bearing point:

> **The FFT does not have to run on the render thread, and it must not.**
> The render-side tap is reduced to **two bounded `memcpy`s into a preallocated SPSC ring**. The FFT,
> the band fold, the ballistics and the snapshot all run on the **consumer** (main actor), inside an
> **unmodified `MasterMixAnalyzer`**.

| §4.3 problem | Status under this design |
|---|---|
| (a) `Task`-based publish allocates → needs a novel render-safe band publish | **Dissolved.** Only samples cross. No seqlock, no fixed-inline band storage, no new snapshot type. |
| (b) FFT ~10–20 µs/hop lands in the render budget | **Dissolved.** Zero FFT, zero floating-point arithmetic render-side. Two memcpys. |
| (c) ~100 KB/instance state | **Confirmed and moved.** ~230 KB per *armed* insert, all consumer-side, **0 bytes when disarmed**. |
| PC2 "must not become a third home" | **Structurally satisfied.** Nothing moves, nothing is extracted, nothing is forked. The insert path calls `MasterMixAnalyzer.processMix` — the same function the master tap calls at `AudioEngine.swift:3057`. |

It also removes a question §4.3 could not answer cheaply: *is `vDSP.FFT.forward` allocation-free on the
render thread?* This design never asks.

---

## 1. Confirm-or-correct verdict on §4.3

### 1.1 What still holds

- **The seam's shape.** A per-insert tap belongs on `ChainEffectUnit` — it already owns per-insert
  identity and preallocated scratch (`EffectChainProcessor.swift:17`, scratch `:44-62`).
- **The `daw_atomic_ptr` retire-bin precedent** for arming (`EQEffect.swift:56-121`; the closer twin is
  `EffectChainProcessor.publish` at `:287-295` with its `retired` bin at `:268`).
- **"Reuse the 24-band shape"** — now literal: the tap produces a real `MasterAnalysisSnapshot`
  (`DAWCore/Model.swift:2004`), from the same analyzer, not a look-alike.
- **PC5's confirmation**: the master path rides AVFoundation's serial tap queue (`installTap`,
  `AudioEngine.swift:3032`) and publishes via `Task { @MainActor }` (`:3071`); both forbidden
  render-side. The m22-b deferral was honest.

### 1.2 What is corrected

**C1 — The hook goes in the WALK LOOP, not in `processActive`. A semantic correction, not a stale anchor.**
§4.3 names both `EffectChainProcessor.process` and `ChainEffectUnit.processActive` as host, ambiguously.
Hosting inside `processActive` (`:180`) **silently misses two of the three walk paths**: a steadily
bypassed unit is skipped entirely (`:375-377` — `if fadeActive … else if !bypassedNow`, so a bypassed
unit calls *neither* branch), and a crossfading unit routes through `renderCrossfade` (`:375`) whose
internal `processActive` call at `:220` happens *before* the equal-power mix at `:224-236` — a tap there
reads pre-mix wet, not the unit's actual output.
The call belongs **at the end of the per-unit loop body**, immediately after `:378`, inside the loop
ending at `:379`. There it observes the unit's true output in all three states, including the honest
"a bypassed EQ outputs its input".

**C2 — One call site covers every strip type.** The walk has three callers and both overloads funnel
into the `:348` body: `InstrumentSourceNode.swift:652` (idle/tail) and `:717` (normal) → keyless
overload `:339` → `:348`; `ChainHostAU.swift:320` (audio-track sandwich, bus sandwich, **and** master)
→ keyed overload `:348`. Instrument tracks, audio tracks, buses and master are all covered by one hook.

**C3 — Offline render cannot collide with an armed tap, and cannot be used to gate it.**
`AudioEngine.renderMixdown` builds `OfflineRenderer()` (`AudioEngine.swift:1588`, `:1633`), which
constructs its **own** `PlaybackGraph` (`OfflineRenderer.swift:246`, `:464`) on its own `AVAudioEngine`.
Consequences: (i) no "offline must not write to a tap" rule is needed — an export physically cannot
stomp an armed tap; (ii) the armed-vs-disarmed byte-identity gate leg is **unbuildable through
`OfflineRenderer`** and *must* live at `EffectChainProcessor` level. A requirement, not a preference.

**C4 — §4.3's inference (b) is invalid.** "The master path is off the render thread, therefore a
per-insert tap runs *on* the render thread, therefore the FFT lands in the render budget." The second
clause is true (there is no per-insert AVFoundation tap point); the third does not follow. Only the
*sample capture* must be render-side. §4.3 conflated "the tap point is on the render thread" with
"the analysis is on the render thread."

**C5 — PC4's four stale anchors confirmed and superseded** by this document's anchors.

---

## 2. The design

### 2.1 The tap object

New file: `Sources/DAWEngine/Analysis/InsertSpectrumTap.swift` —
`final class InsertSpectrumTap: @unchecked Sendable`, with the split-ownership threading contract
`EffectChainProcessor` documents at `:256-265`:

| Member | Owner | Notes |
|---|---|---|
| `ringL`, `ringR` — `UnsafeMutablePointer<Float>`, `capacityFrames` each | render writes / consumer reads | non-interleaved, always 2 channels |
| `writeIndex` — `UnsafeMutablePointer<daw_atomic_u64>` | render writes (release), consumer reads (acquire) | monotonic frame counter, never wrapped; slot = `index % capacity` |
| `readIndex` — plain `UInt64` | consumer only | single reader |
| `droppedFrames` — `UnsafeMutablePointer<daw_atomic_u64>` | consumer increments | the observable drop counter (gate leg) |
| `analyzer: MasterMixAnalyzer` | consumer only | constructed at arm time with the graph rate |
| `stagingL`, `stagingR` — `maxDrainFrames` each | consumer only | drain-and-validate buffer |
| `channelPointers` — preallocated 2-element pointer array | consumer only | so `processMix` needs no per-poll allocation |

**Sizes (fixed `static let`, justified):**
- `capacityFrames = 16_384` → 341 ms @ 48 kHz; **2× the 8192-frame max quantum**
  (`ChainEffectUnit.scratchFrames`, `:20`) so one pathological max quantum can never fill the ring. 128 KB.
- `maxDrainFrames = 4_096` → 85 ms; a 46 fps poll needs ~1044. 32 KB.
- Analyzer raw buffers ≈ 70 KB (`MasterMixAnalyzer.swift:142-153`, `:183-184`).
- **Total ≈ 230 KB per armed insert. Ceiling 256 KB. Zero when disarmed.**

**Render-side entry point** — the entire render-thread surface of this item:

```swift
func write(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int)
```
1. Guard `frameCount > 0`, `buffers.count >= 1`, and carry `renderCrossfade`'s guard shape (`:203-204`)
   — `buffers.count <= 2`; a 1-channel walk **duplicates ch0 into both ring channels**, matching
   `processMix`'s `channels[channelCount >= 2 ? 1 : 0]` rule (`MasterMixAnalyzer.swift:338`).
2. Clamp `n = min(frameCount, capacityFrames / 2)`.
3. Load `writeIndex` (this thread is the only writer), compute the slot, `update(from:count:)` in at
   most two spans per channel (wrap split). **≤ 4 memcpys, no arithmetic, no branches on data.**
4. `daw_atomic_u64_store(writeIndex, w + n)` — release, pairing with the consumer's acquire load.
   **No new C shim needed:** `CAtomics.h:31-35` already provides release-store / acquire-load.

No allocation, no locks, no ObjC, no libm, no FFT; bounded by `frameCount`. It **reads** the audio
buffer and writes only to its own ring — the signal is structurally untouched.

**Consumer-side entry point** (main actor): `func drainAndSnapshot() -> MasterAnalysisSnapshot`
1. `w = daw_atomic_u64_load(writeIndex)` (acquire). `available = w - readIndex`.
2. If `available > maxDrainFrames`: `readIndex = w - maxDrainFrames`, count the drop. **Drop oldest.**
3. Copy the pending span (≤ 2 spans per channel) into `stagingL/R`.
4. **Re-load `writeIndex`. If it advanced past `readIndex + capacityFrames`, the staged block was
   potentially stomped mid-copy → discard, count the drop, return the previous snapshot.** The only
   tear defence needed, and it is exact.
5. `readIndex += n`; `analyzer.processMix(...)`; `return analyzer.snapshot()`.

`snapshot()`'s 24-element allocation (`:462`) is legal here — main-actor tier, the same tier the master
path already allocates on ~46×/s.

### 2.2 Why this is the same numbers as the master, not merely similar

Both paths call `MasterMixAnalyzer.processMix(channels:channelCount:frameCount:)` on raw L/R. Same
`fftSize` 2048 / `hopSize` 1024 (`:62`, `:64`), same `bandEdges` (`:116`), same `bandBinStart/Count`
derivation (`:248-269`), same ballistics (`:89-96`), same −80 floor. **PC2's "structural, not
coincidental" is satisfied at the strongest available level: not shared constants, but a shared
implementation.**

**One caveat an implementer must not get wrong:**
- **Bands are chunk-invariant, bit-exactly.** `process` funnels everything through the fixed 2048/1024
  FIFO (`:302-315`) and the mono sum is elementwise, so band output depends only on the sample
  *stream*, never on chunking.
- **`correlation` / `width` / `balance` are NOT chunk-invariant.** `accumulateStereo` (`:368-402`)
  accumulates per-chunk `vDSP_dotpr` Float partials into Double sums (`:381-383`); different chunk
  boundaries regroup the partials and change the last ulp.
- **Therefore: pin `bands` bit-identically; assert the stereo fields with a tolerance.** Pinning the
  stereo fields bit-exactly across differently-chunked feeds will fail intermittently — exactly the
  flake class this repo already has three of.

### 2.3 Display latency — the one honest cost of the pivot

Analyzer window 2048 @ 48 kHz = **42.7 ms**, plus up to one poll interval (~17–21 ms) ≈ **~60 ms**
transport-to-pixel, before the smoother's own attack (~4 frames ≈ 85 ms to 94%). The master path is
comparable, not better: its tap fires on 1024-frame buffers ≈ 21 ms of accumulation, plus the same
42.7 ms window, plus a `Task` hop. **This is why the comparability gate compares settled steady state,
not transients.**

---

## 3. The four open questions

### Q1 — Pre- or post-insert tap → **POST**

The tap reads the buffer after the unit has processed it, so the overlay shows what the EQ **produces**.

1. **PRE would reproduce the bug that opened this item.** The user's report is "the EQ does not show the
   dynamic frequency". Under PRE, a 12 dB cut at 300 Hz moves *nothing* on screen — that reads as a
   broken control. Under POST the cut visibly carves the fill; the tool teaches itself.
2. **POST is the only choice consistent with the master overlay.** The master's spectrum comes from
   `installMeterTap` on the master chain host's output (`AudioEngine.swift:3001-3005`) — post-fader,
   post-chain, therefore *post* the master EQ. A PRE track tap would make the two overlays mean
   opposite things while the gate demands point-comparability. That alone settles it.
3. **The double-counting objection is structurally prevented.** §4.1 already puts the spectrum on a
   different y-mapping from the curve (bands −72…−6 dB → 0…0.85 of plot height; curve ±24 dB over the
   full height) and declares it "context, not a measurement readout". A 6 dB cut in the curve does not
   visually equal a 6 dB drop in the fill, so "did I cut 12?" cannot arise from the geometry.
4. **A bypassed unit is handled honestly.** The steady-bypass branch does nothing, so a post tap placed
   after the branch reads the untouched input — which *is* the bypassed EQ's output. A/B-ing bypass
   visibly moves the spectrum. That is a feature.

**What PRE would have meant:** "what this insert receives" — genuinely better for the *diagnostic* half
of EQ ("where is the mud?"). One extra call site at the **top** of the loop body plus a second arm flag.
**Not built in v1.** If m23-o wants a stable pre-EQ reading, file `m23-r5 (pre/post toggle)`; the tap
object needs no change, only a second slot on the unit.

**Two facts POST forces into the copy and the fixtures:**
- The insert tap sits **pre-PDC-compensation and pre-fader** (`compensation.process` runs after
  `chain.process`, `InstrumentSourceNode.swift:720` / `ChainHostAU.swift:324`). **Moving the track
  fader does not move the track EQ's spectrum.** Standard plugin-analyzer behaviour, but state it.
- The master overlay is post-*whole-chain*; the insert overlay is post-*this-insert*. Band **geometry**
  is identical; **semantics** differ by whatever else is in the chain after the EQ. Note it; do not
  paper over it.

**Filed follow-up (NOT in m23-r):** once the tap exists, the master EQ could feed from its own
per-insert tap, making both overlays exactly identical in meaning. Rejected for v1 — the master's
spectrum is currently free, `debug.vibeSeed` depends on the existing path, and switching it puts
m22-b's accepted captures at risk for no user-visible gain.

### Q2 — The arming policy → **explicit arm, one home in `AudioEngine`, observed render-side via `daw_atomic_ptr`**

**Who arms.** The view. `EQCurveEditor` takes the arm in a `.task { }` keyed on the editor target and
releases on task cancellation (survives target switching without an `onDisappear` race):

```
EQCurveEditor (.task)
  → AppModel
  → ProjectStore.setInsertAnalysisArmed(trackID:effectID:armed:) -> Bool        [DAWCore, engine-free]
  → AudioEngineProtocol.setInsertAnalysisArmed / setMasterInsertAnalysisArmed   [DAWCore/EngineProtocol.swift]
  → AudioEngine                                                                 [ONE HOME of arm intent]
  → PlaybackGraph.effectChainState(forTrack:) / masterChainState
  → EffectChainState.setAnalysisArmed(effectID:armed:)                          [allocates/destroys the tap]
  → ChainEffectUnit.tapSlot  (daw_atomic_ptr publish + retire bin)
```

Not a new pattern — it is the m22-e gain-reduction path verb for verb:
`EffectChainState.gainReductionDb(forEffect:)` (`:505`) → `PlaybackGraph.effectGainReductionDb`
(`PlaybackGraph.swift:1203`) / `masterEffectGainReductionDb` (`:1210`) → `AudioEngineProtocol`
(`EngineProtocol.swift:590`, `:595`) → `ProjectStore` (`:2916`, `:2923`) → `AppModel.gainReductionDb`
(`DAWProApp.swift:1152`). **Follow it exactly, including the track/master split and the extension
defaults idiom at `EngineProtocol.swift:954`** — `insertAnalysis…` defaults to `nil`,
`setInsertAnalysisArmed` defaults to `false`, so a fake engine is honestly unarmed rather than
fabricating floors.

**Which actor: main, throughout.** Ring + analyzer allocation happens on the main actor at arm time.
Nothing in the arm path touches the render thread except the final atomic store.

**How the render thread observes the arm without a lock.** A new member on `ChainEffectUnit`:
`let tapSlot: UnsafeMutablePointer<daw_atomic_ptr>` (heap, stable address, init nil), allocated in
`init` beside `bypassFlag`/`resetFlag`/`useKeyFlag` (`:83-88`) and deallocated in `deinit` (`:98-103`).
Arming = `daw_atomic_ptr_exchange(tapSlot, Unmanaged.passRetained(tap).toOpaque())`; the displaced tap
goes to a **≥ 1 s retire bin on `EffectChainState`** (main-actor only), the `publish` recipe verbatim
(`:287-295`). The walk does one `daw_atomic_ptr_load`; nil → skip; else `takeUnretainedValue()` +
`write(...)`.

*Unit lifetime is already safe:* a removed unit dies with the **retired snapshot** (`:473`), held ≥ 1 s,
so the render thread can never borrow a freed unit or a freed `tapSlot`.

**The invariant that makes arming free: arming must never republish the chain.** `sync` republishes only
when `newIdentity != oldIdentity`, and identity is `(id, kind)` only (`:411-414`, `:434-435`, `:472`).
An arm is one atomic store on an existing unit — the `setBypassed`/`setUsesKey` convention (`:111-116`,
`:144-146`). **Opening and closing the EQ editor therefore does not rebuild the unit, does not reset DSP
state, and does not click.** Gate it: `state.unit(forEffect:) === the same instance` across
arm → disarm → arm.

**Arm survival — the three re-application points (the third is easy to miss):**
1. **`EffectChainState.sync`** re-applies its `armedEffectIDs: Set<UUID>` to whatever unit currently
   backs each id, **every pass**, idempotently. Covers unit replacement on kind change and
   `invalidateEffect(id:)` (`:535-539`).
2. **`PlaybackGraph` strip construction** — a strip rebuilt mid-session gets a fresh `EffectChainState`
   (`PlaybackGraph.swift:1828`, `:1957`), whose armed set is empty.
3. **`AudioEngine` graph rebuild** (`AudioEngine.swift:424`, `:951`) — **this is the hole.**
   `AudioEngine` holds the arm intent as `Set<InsertAnalysisKey>` (key = `(trackID: UUID?, effectID:
   UUID)`) and **re-applies it immediately after every graph build**. Without this, a mid-session engine
   rebuild leaves the editor open and the spectrum silently, permanently dead — the exact m3c failure
   class. `ProjectStore` holds **no** intent; it forwards, like every other engine call.

**The m3c-shaped premise every gate must honour: a freshly armed tap legitimately reads `.floor`.**
Non-floor bands require ≥ 2048 rendered frames (~43 ms) *plus* a drain. **Arm → render/play ≥ 100 ms →
poll.** Any leg that arms and immediately reads is measuring the premise, not the feature.

**The N cap: REFUSE the 9th, never evict.** `AudioEngine` caps simultaneous armed taps at **N = 8** and
`setInsertAnalysisArmed` returns `false` at the cap. Eviction would make a previously-armed tap silently
stop producing — REFUSE-DON'T-CORRUPT. The UI can only ever arm one (`ContentView.swift:370` presents a
single `EffectEditorOverlay`), so the refusal is only reachable from r4's wire path, where it becomes a
teaching error. **The cap is what turns "stated budget" into an enforced bound rather than a hope.**

**Disarm points:** task cancellation / editor close (r3); lease expiry (r4); effect removal and track
deletion (via `sync`'s armed-set pruning); `AudioEngine.shutdown()`.

### Q3 — The publish idiom → **`daw_atomic_ptr` retire-bin for the ARM; lock-free SPSC ring for the DATA**

§4.3 posed this as "retire-bin *or* seqlock, publishing bands". Under §2 the question decomposes and
both halves get an existing house answer:
- **The arm** (a pointer, changing at human rate) → `daw_atomic_ptr` + ≥ 1 s retire bin. Exactly
  `EffectChainProcessor.publish` (`:287-295`) and `EQEffect.apply(params:)` (`:98-110`).
- **The data** (samples, every quantum) → SPSC ring with release/acquire `daw_atomic_u64` indices,
  already available at `CAtomics.h:31-35`. **No shim change.**

**Why not a seqlock over fixed-inline band storage** (the §4.3 alternative): it requires the FFT
render-side, which requires a render-safe analyzer, which means either a second STFT front-end + second
ballistics or a refactor of `MasterMixAnalyzer.snapshot()` to fill a caller-provided buffer. **That is
the third home PC2 forbids**, and it puts a refactor under the m22-a/b and vm-a pins for no benefit. It
also drags in the unanswered `vDSP.FFT.forward` allocation question, NaN guards on the render thread,
and a novel writer-priority analysis. Rejected.

**Why a ~46 fps main-actor poll is the right consumer:** a 17–21 ms poll interval against a 341 ms ring
is **16–20× headroom**; the drop path is unreachable in normal operation and exists only so a UI stall
degrades gracefully instead of tearing. `TimelineView(.animation)` is already `paused` when the window
is inactive (`EQCurveEditor.swift:237`) — the ring fills, the reader drops on resume, and the display
re-converges within a few frames. And when the editor is closed there is **no consumer and no producer
at all**, which is what "idle inserts pay nothing" has to mean.

### Q4 — The stated budget

**N = 8** simultaneously armed inserts, **structurally enforced** (the cap in Q2), not aspirational.

| Quantity | Ceiling (gate) | Design target |
|---|---|---|
| Armed insert, render-side, per 512-frame quantum @ 48 kHz | **≤ 3 µs** (0.028% of the 10.67 ms budget) | ~0.2 µs (4 KB copied) |
| Aggregate at N = 8 | **≤ 24 µs/quantum** (0.22%) | ~1.6 µs |
| **Disarmed** insert, per unit per quantum | **≤ 100 ns** (one acquire load + branch) | ~2 ns |
| Heap allocated render-side, ever | **0 bytes** | 0 |
| Memory per armed insert | **≤ 256 KB** | ~230 KB |
| Memory per disarmed insert | **0 bytes** | 0 |

**How to measure — three legs, all headless, all at `EffectChainProcessor` level (C3 makes this
mandatory):**
1. **Allocation leg (both directions).** Drive 10,000 armed 512-frame quanta through
   `processor.process(bufferList:frameCount:)` in a preallocated loop. **Use the `malloc_logger`
   probe, NOT `blocks_in_use`.** *Positive counterpart:* `writeIndex` advanced by exactly
   `10_000 × 512` and a drain produces non-floor bands — so a tap that allocated nothing *because it
   did nothing* fails.

   > **CORRECTION, measured at m23-r1 (2026-07-28) — this paragraph previously specified
   > `malloc_zone_statistics(malloc_default_zone(), …).blocks_in_use` delta == 0 and called it "the
   > only leg that actually observes the invariant." That is BACKWARDS for the allocation class that
   > actually threatens r2.** `blocks_in_use` is a *level*, not a counter: an allocate-then-free
   > inside the measurement window nets to zero and malloc reuses the block, so the probe is blind to
   > **transient** allocation and sees only *retained* allocation. Proven by mutation at r1 — a
   > deliberate per-call 4-element array allocation in `write` left the `blocks_in_use` leg **green**,
   > while a `malloc_logger` probe (resolved via `dlsym(RTLD_DEFAULT, …)`, thread-filtered with
   > `pthread_threadid_np`) failed it at 800 events.
   >
   > This matters most **here**, at r2: a transient alloc from a dynamic cast, a boxed closure or an
   > ObjC bridge is exactly what chain integration can introduce, and it is precisely what the old
   > probe cannot see. See `InsertSpectrumTapTests.swift` for the working implementation — and note
   > that `malloc_logger` being unavailable must be recorded as a **failure, not a skip**.
   >
   > Two consequences beyond this file. (a) The same blind probe was used as the empirical backstop
   > for **m23-d's C15** RT-safety claim ("`blocks_in_use` delta 0 across 10 000 audition-carrying
   > quanta, 4 runs"); that cycle's *structural* argument stands, but its measured backstop only ever
   > ruled out retained allocation. (b) Under `-Onone`, `for _ in 0..<n {}` with an empty body raises
   > ~2 malloc/free events per iteration from `Range` iteration itself, while the identical `while`
   > loop raises zero — so any measured loop must be a `while` loop.
2. **Cost leg.** Same harness, `ContinuousClock`: disarmed baseline, then armed. Assert
   `(armed − disarmed) / quanta ≤ 3 µs` and `disarmed_delta ≤ 0.2 µs`. Print with the repo's
   `[measured]` convention. The 3 µs ceiling is ~15× the expected value, so a loaded machine still
   passes — the leg guards against an *architectural* regression (someone putting the FFT back on the
   render thread costs 10–20 µs/hop and blows it), not a microbenchmark.
3. **N-scaling leg.** Arm 8 units in one chain; assert aggregate ≤ 24 µs/quantum **and** all 8 produce
   non-floor bands (positive), **and** the 9th arm returns `false` with `tapSlot` still nil (negative).

---

## 4. The split

Four sub-items. r1/r2 share a route but are separate cycles with separate gates — the
PIN-BEFORE-DELEGATING pattern: **r1's gate proves SPSC correctness in isolation, so a weak r1 gate
surfaces before anything touches the walk or the null pin.**

### r1 — `InsertSpectrumTap`: the ring + the consumer, standalone
**Route:** `audio-dsp-engineer`. New: `Sources/DAWEngine/Analysis/InsertSpectrumTap.swift`;
`Tests/DAWEngineTests/InsertSpectrumTapTests.swift`. No chain integration, no UI, no wire.

**GATE (both directions):**
- **Fidelity, positive:** feed a known stereo stream through `write(...)` in irregular chunk sizes
  (37, 512, 1024, 3000 frames); drain; assert `snapshot().bands` is **bit-identical** to a fresh
  `MasterMixAnalyzer` fed the same stream in one shot. *(Bands only — §2.2. Stereo fields get a ≤ 1e-5
  tolerance, and the test must say why, or a later cycle will "fix" it into a flake.)*
- **Fidelity, negative (discriminator):** the same assertion **fails** when the stream is perturbed by
  one dropped 1024-frame block — proving the leg can see a broken ring.
- **Drop policy, positive:** at a normal cadence, `droppedFrames == 0` across 10 s of simulated audio.
- **Drop policy, negative:** force a stall (40,000 frames, no drain); assert `droppedFrames` increments
  by the expected count **and** the analyzer recovers to correct steady-state within 10 normal drains.
  *(State in-test: sustained drops shorten the sample stream and the ballistics are per-hop not
  per-wall-second, so a dropping tap runs its ballistics slow — which is why the comparability fixtures
  must assert `droppedFrames == 0`.)*
- **Tear defence:** stage a drain, forcibly advance `writeIndex` past the staged block, assert the block
  is **discarded and counted**, not consumed.
- **Channel rule:** a 1-channel `write` produces a snapshot bit-identical to duplicated stereo.
- **Allocation:** the allocation leg against `write(...)` alone — **both probes**, retained
  (`blocks_in_use`) *and* transient (`malloc_logger`), paired with the index-advance assertion in the
  SAME test. See the CORRECTION under §4/r2 leg 1: `blocks_in_use` alone is blind to transient
  allocation and was shown green against a deliberately-allocating mutant.
- Suites green; 0-warn forced-full build.

### r2 — Chain integration + arm plumbing (the null-pin cycle)
**Route:** `audio-dsp-engineer`. Touches `EffectChainProcessor.swift` (`tapSlot` beside `:83-88`/
`:98-103`; the hook after `:378`; `setAnalysisArmed` + `armedEffectIDs` re-applied in `sync` near
`:460-470`; the tap retire bin), `PlaybackGraph.swift` (twins beside `:1203`/`:1210`),
`AudioEngine.swift` (arm-intent set + re-apply after graph builds at `:424`/`:951`),
`DAWCore/EngineProtocol.swift` (two arm fns + two read fns + extension defaults, the `:590`/`:595`/
`:954` idiom), `DAWCore/ProjectStore.swift` (forwarders beside `:1185`, `:2916`).
New: `Tests/DAWEngineTests/InsertSpectrumChainTests.swift`.

**GATE (both directions):**
- **THE NULL PIN — read first.** `04e86aec9a73c505` (`Tests/DAWEngineTests/EQv2Tests.swift:229-241`)
  **structurally cannot see this item.** It constructs `EQEffect` directly and never touches
  `ChainEffectUnit` or `EffectChainProcessor`. Citing it as this item's bit-exactness gate is
  **vacuous**. The real chain-walk pin is `nullEraChainRenderByteIdentical`
  (`Tests/DAWEngineTests/ChainClickPolishTests.swift:524`, SHA
  `0a6fc1c5d68c025bbde78b7fb4c9c3062f606494a042936316ff323d743bcd45`). **Keep both green unchanged, and
  add the actual discriminator: armed-vs-disarmed byte identity at processor level** — same input, same
  chain, once armed and once disarmed; outputs **bit-identical sample for sample**. Both directions:
  assert identity (safety) **and** prove liveness with **TWO SEPARATE assertions that do not substitute
  for each other**: (i) the ring's **write index advanced**, and (ii) the drained bands are **non-floor**.
  These fail differently and neither implies the other — a ring that advances while the drain path is
  broken yields floor bands and satisfies (i) alone; a tap reading a stale prior fill yields non-floor
  bands and satisfies (ii) alone. Assert both, or "identical because the tap never ran" cannot be
  distinguished from "identical because the tap worked and stayed out of the way".
- **The pre/post pin (makes Q1 unrepresentable-by-accident).** Sync one EQ with a large cut at a known
  band (−18 dB @ 3 kHz), arm, drive 512-frame chunks over ~1 s of broadband + sines, drain:
  *positive:* tapped bands bit-identical to a `MasterMixAnalyzer` fed a standalone `EQEffect`'s output
  over the same input/params; *discriminator:* the tapped 3 kHz band differs from a reference analyzer
  fed the **dry** input by ≈ the cut depth. **A PRE tap passes the first and fails this one.** Assert
  `droppedFrames == 0` (the fixture's premise).
- **Every strip type reaches the tap:** one leg each for an instrument-track chain
  (`InstrumentSourceNode`), an audio-track/bus chain and the master chain (`ChainHostAU`) — each armed,
  each producing non-floor bands. Without this a whole strip class is silently spectrum-free and no cost
  leg would notice.
- **Bypass honesty:** a steadily-bypassed unit's tap reads bands **equal to its input**; un-bypassing
  moves them. A crossfading unit's tap reads the post-mix result.
- **Arm lifecycle:** arm → render → non-floor; disarm → `tapSlot == nil`, memory released;
  `state.unit(forEffect:) === same instance` across arm/disarm (no republish, DSP state survives);
  `sync` with a changed **kind** rebuilds the unit and the tap **is re-applied**; `invalidateEffect(id:)`
  then `sync` — same; a rate change (`sync` at 96 kHz) re-creates the analyzer at the new rate;
  **graph rebuild with the arm held** (the `EngineRebuildTests.swift` harness is the model): rebuild →
  render → **non-floor again**, not floor and not stale.
- **The cap:** 8 arm; the 9th returns `false` and leaves `tapSlot` nil.
- **Budget:** the three legs of §Q4, printed `[measured]`.
- **Premise preamble:** every leg arms then renders ≥ 100 ms before reading. State it in the file header
  so a later cycle does not "simplify" it away.
- Suites green; 0-warn forced-full build; wire count unmoved (r2 adds no commands).

### r3 — UI enablement (**a HALF cycle — PC3 is right**)
**Route:** `ui-design-engineer`. Touches `EffectEditorOverlay.swift:143` (flip `showsSpectrum`),
`EQCurveEditor.swift:45-49` (target-aware closure), `:121-123` (the help string), a `.task` for arming,
`DAWProApp.swift` (a `debug.insertSpectrumSeed` beside `debug.vibeSeed`).
**Not a full agent's cycle; must not be padded into one.**
1. `showsSpectrum:` becomes `true` for every EQ instance.
2. `spectrum:` closure: `trackID == nil` → `vibeSeed ?? store.masterAnalysis()` (unchanged); otherwise
   → `insertSpectrumSeed ?? store.insertAnalysis(trackID:effectID:) ?? .floor`.
3. `.task(id: target)` arms on entry, releases on cancellation.
4. The help string at `:122` is hardcoded master-specific and **must** fork: master → unchanged;
   track → *"The green fill is the live spectrum **after** this EQ — context only; its height is not the
   EQ's dB scale."* The word **after** is the Q1 decision made visible.
5. `debug.insertSpectrumSeed {trackId?, effectId, bands[24]}` — app-tier, **off `allCommands`/MCP** by
   the `debug.vibeSeed` convention — so the staging capture is deterministic.

**GATE:** staging capture of a **track** EQ card with a live spectrum (positive) **and** a capture of the
master EQ card unchanged from m22-b (no regression); with the tap disarmed / engine stopped the track
card draws the **floor** silhouette, not a fabricated one (honesty); arm/disarm proven through the seam,
not "the pixels changed"; **explicitly supersede** the m22-b pixel review's "track curve honestly
spectrum-free" capture in the close-out record — it was recorded as expected state and a future reviewer
must not treat it as a pin. Suites + npm green.

### r4 — `fx.spectrum` + MCP tool (the constitution's every-capability rule)
**Route:** `mcp-integration-engineer`. Strictly additive; never touches `fx.setParam`/`fx.describe`.
`fx.spectrum {trackId?: uuid, effectId: uuid, arm?: bool}` →
`{bands: [24], levelDb, peakDb, centroidHz, flux, armed: bool}`. Deliberately **not** on the always-on
`project.snapshot` payload — the `MasterScopeFrame` precedent (raw data stays off the always-on wire).
**The lease lives here and only here:** a wire arm is a **TTL lease** (3 s) refreshed by each call, held
on the main actor above the engine's refcount-free arm. Expiry is **lazy** — swept on every
`fx.spectrum` call, on `transport.stop`, and on `project.snapshot`. Backstop: the N = 8 cap means a
leaked lease costs ≤ 230 KB and ≤ 3 µs/quantum and can never grow unbounded.

**GATE:** round-trip over the control port — arm → play ≥ 200 ms → `fx.spectrum` returns **non-floor**
bands whose peak band matches an injected tone's band (`MasterMixAnalyzer.bandIndex(containing:)`,
`:123`) — *a real discriminator, not "24 numbers came back"*; the same call on a **silent** track returns
the floor exactly; the 9th arm refused with a **teaching error naming the cap**; lease expiry proven
(arm, stop calling, sweep, assert disarmed); unknown effect/track id refused without partial mutation;
MCP tool registered and its arg schema rejects an unknown key at the boundary; suites + npm;
**wire count moves by exactly the additive delta and is pinned.**

**Ordering:** r1 → r2 → r3 → r4. **m23-o runs after r3** (it surfaces on top of the overlay); it does not
need r4.

---

## 5. PC1–PC5 audit

- **PC1 — conclusion CONFIRMED; its reasoning corrected in a way that makes it stronger.** Confirmed:
  zero `SpectrumBandFold` references in `MasterMixAnalyzer.swift`; the only consumers are
  `ReferenceAnalyzer.swift:271` and `AudioContentAnalyzer.swift:252/:257`.
  **Correction:** PC1 says building on `SpectrumBandFold` "would make the track curve NOT
  point-comparable". That overstates it — `SpectrumBandFold.bandsDb` **already folds into
  `MasterMixAnalyzer.bandEdges`** (`:69-70`) and carries an `emptyBandReadsNearestBin: true` mode
  documented at `:28-36` as the `MasterMixAnalyzer` live convention. At 2048-pt geometry that route
  *would* be band-comparable by explicit design. **The real reason to reject it is stronger:
  `SpectrumBandFold` is a FOLD, not a FRONT-END** — no FFT, no FIFO, no ballistics, and it consumes
  allocated `[Double]` mean-power arrays. Building on it means a second STFT front-end and a second set
  of ballistics — **the third home PC2 forbids.** Same verdict, sounder ground; and the sounder ground
  is what rules out the seqlock alternative in Q3 too.
- **PC2 — CONFIRMED, and satisfied more strongly than it asks.** This design does not *derive from*
  `bandEdges` — it *is* it. **No shared extraction is warranted. Nothing moves. There is no null-pin
  risk, because no existing file's math is touched.** `MasterMixAnalyzer.snapshot()`'s allocation stays
  main-actor-tier and is simply never called render-side — no fixed-inline storage is needed, because
  nothing render-side ever holds bands.
- **PC3 — CONFIRMED; r3 is a half cycle.** The only work PC3 does not name is the arming lifecycle
  (`.task`) and `debug.insertSpectrumSeed` for a deterministic capture — both small.
- **PC4 — CONFIRMED, every anchor re-verified. And PC4 undersells itself: `processActive` was the
  *wrong host* even when the line number was right** (C1). Line numbers rot; that one was a semantic
  error from day one.
- **PC5 — CONFIRMED as description, CORRECTED as inference.** The arming policy is real and is the
  subtlest part (Q2). The "preallocated lock-free publish" of *band data* is **not needed at all** — what
  crosses is samples, and the crossing is a textbook SPSC ring on atomics the repo already ships. The
  item is **materially cheaper and materially safer** than PC5 estimates.

**Three additional findings:**
1. **The gate's cited null pin is vacuous for this item** (see r2). The roadmap's own gate leg cannot
   see the change it is guarding.
2. **Offline render is structurally isolated** (C3) — an export cannot stomp an armed tap, *and* the
   byte-identity leg cannot be built through `OfflineRenderer`.
3. **Bands are chunk-invariant bit-exactly; the stereo fields are not** (§2.2). Pinning the wrong field
   is a manufactured flake.

---

## 6. ARCHITECTURE.md entry (to be written at r2's close-out)

> - **Per-insert spectrum analysis (m23-r): SETTLED (2026-07-27; design
>   `docs/research/design-m23r-per-insert-spectrum-tap.md`; supersedes `design-m22b-eq-curve-editor.md`
>   §4.3)** — the render thread performs **no analysis**. A per-insert tap is two bounded `memcpy`s into
>   a preallocated SPSC ring (release/acquire `daw_atomic_u64`, `CAtomics.h:31-35`); the FFT, band fold,
>   ballistics and snapshot run on the **consumer** inside an **unmodified `MasterMixAnalyzer`**, so
>   track and master spectra are comparable by shared implementation rather than shared constants —
>   **there is no second front-end and no third band fold.** The tap is **POST-insert** (the overlay
>   shows what the EQ produces, matching the master's post-chain tap and making a cut visibly do
>   something); the hook is the **walk loop body** in `EffectChainProcessor.process`, *not*
>   `processActive`, which would miss the bypassed and crossfading paths. Arming is one
>   `daw_atomic_ptr` store with the ≥ 1 s retire bin — never a chain republish, so DSP state survives
>   opening and closing the editor — with the arm **intent** homed in `AudioEngine` and re-applied after
>   every graph rebuild, and a **structurally enforced cap of N = 8** that REFUSES the ninth rather than
>   evicting. Budget: ≤ 3 µs/quantum/armed insert, ≤ 100 ns disarmed, 0 bytes allocated render-side,
>   ≤ 256 KB per armed insert and 0 when disarmed. Superseded m22-b capture: "track curve honestly
>   spectrum-free" is no longer expected state.

---

## 7. Orchestrator verification (independent, 2026-07-27)

Three load-bearing claims were re-measured by the orch pass before this design was accepted:

1. **Null-pin vacuity — CONFIRMED.** `sed -n '229,241p' Tests/DAWEngineTests/EQv2Tests.swift` shows the
   pin constructs `EQEffect(params:)` directly and compares against `LegacyEQReference`;
   `grep -c "ChainEffectUnit\|EffectChainProcessor" Tests/DAWEngineTests/EQv2Tests.swift` returns **0**.
   The roadmap's m23-r gate leg citing `04e86aec9a73c505` is vacuous for this item.
2. **C1 hook point — CONFIRMED.** `EffectChainProcessor.swift:373-378` reads
   `if unit.fadeActive { renderCrossfade(...) } else if !bypassedNow { processActive(...) }` — a
   steadily-bypassed unit calls **neither**. `renderCrossfade` calls `processActive` at `:220`, before
   the equal-power mix at `:224-236`. Hosting the tap in `processActive` would miss two of three paths.
3. **C3 offline isolation — CONFIRMED.** `OfflineRenderer.swift:246` and `:464` each construct
   `PlaybackGraph(engine:graphRate:)` — its own graph, never the live one.
