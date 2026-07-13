# Design spike (m13-f): Gapless loop wrap

**Status: DESIGN + KEPT SPIKE ONLY — no production changes. Gates M14 implementation.**
**Author: audio-dsp-engineer, 2026-07-12.**
**Scope:** the roadmap item (docs/ROADMAP.md:219): the ~60 ms restart-primitive seam at loop wrap, with the metronome toggle, loop-cycle take recording (M5 iii-b), and the F9 bypass-click/stop-tails items parked on this verdict.

Every claim about current behavior cites file:line evidence read for this spike. Every number marked **[measured]** comes from the kept spike suite `Tests/DAWEngineTests/GaplessLoopSpikeTests.swift` (run 2026-07-12, macOS 26 / Darwin 25.4, offline manual rendering at 48 kHz / 512-frame pulls; logs in the m13f scratchpad evidence dir).

> Citation drift note: the roadmap item cites AudioEngine.swift:1340-1343 and PlaybackGraph.swift:1682-1685 (audit-era lines). Both files have grown since; the same code now lives at AudioEngine.swift:1376–1383 / 1529–1540 and PlaybackGraph.swift:1866–1874. All citations below are current-line exact.

---

## 1. Decision (summary up front)

**GO-WITH-CONDITIONS (§10). Option A: wrap-aware schedule-ahead on the EXISTING per-clip players — the graph never stops at the wrap.** Cycle N+1's clip segments queue on the same players with explicit player-relative anchors offset by the loop period; MIDI and automation schedules unroll cycles under an append-only-republish law; the metronome unrolls clicks; the 30 Hz playhead task (already doing `Metronome.topUp`) becomes the top-up driver. The restart primitive survives for seeks, tempo/track edits, and loop-bounds edits (documented fallback seam on EDIT only, never on wrap).

The gating primitive is **proven, not assumed**: the L-0 spike shows one `AVAudioPlayerNode` splices two anchored segments **bit-exactly sample-continuous** across a mid-quantum boundary — pre-queued, re-reading the same `AVAudioFile` region, and when the second segment is queued while the first is already rendering **[measured]** (§3). The negative control reproduces today's seam at exactly the production constants: **2880 frames (60.0 ms) of silence + 1680 frames (35.0 ms) of post-loop overshoot** **[measured]** (§2).

---

## 2. The seam today, located and measured

### 2.1 The wrap IS the restart primitive

The playhead task ticks at 33 ms and wraps by restarting everything:

> Sources/DAWEngine/AudioEngine.swift:1526
> `try? await Task.sleep(for: .milliseconds(33))`

> AudioEngine.swift:1529–1540
> ```
> // Loop wrap: on reaching the loop end, jump back to the loop start
> // through the reschedule primitive. That inherits `restart`'s
> // ~60 ms lead-in gap, so the wrap is audible as a brief seam —
> // v0-honest; sample-accurate looping needs pre-scheduled tails.
> // Suppressed while recording: a take is one linear capture, and
> // wrapping would break the writer's single-anchor alignment.
> if self.activeTake == nil,
>    self.loopEnabled, self.loopEndBeat > self.loopStartBeat,
>    beats >= self.loopEndBeat {
>     self.restart(fromBeat: self.loopStartBeat, tempoMap: anchor.tempoMap)
> ```

> AudioEngine.swift:1376–1383
> ```
> /// The single reschedule primitive: stop-all → reschedule-from-beat →
> /// re-anchor → resume. Individual scheduled segments cannot be cancelled;
> /// costs one ~60 ms lead-in gap.
> private func restart(fromBeat beats: Double, tempoMap: TempoMap) {
>     graph.stopAllPlayers()
>     currentAnchor = nil
>     startPlayers(fromBeat: beats, tempoMap: tempoMap)
> }
> ```

The 60 ms is `startLeadSeconds = 0.06` (AudioEngine.swift:220–223). `startPlayers` also rebuilds the metronome queue from scratch (`metronome.stop()` first thing, AudioEngine.swift:1414) and re-schedules every clip (`graph.scheduleAll`, AudioEngine.swift:1415). Loop state is cached scalars fed by transport intents (`cacheTransportFlags`, AudioEngine.swift:1360–1372; `loopChanged` never touches live scheduling, AudioEngine.swift:1094–1100).

`stopAllPlayers` is the flush-everything hammer (PlaybackGraph.swift:1844–1875): players stop (queues clear, player time resets), instrument schedules unpublish + all-notes-off flush (1846–1849), automation unpublishes (1853–1857), **every chain resets — tails cut** (1860–1865), and **PDC rings flush** (1866–1874) with the exact anticipation of this design:

> PlaybackGraph.swift:1868–1873
> "NOTE on loop wrap: the spec keeps rings across a seamless wrap, but this v0 transport implements the wrap AS the restart primitive (players stop, chains reset, ~60 ms reschedule gap) — flushing the rings there matches the chains' existing tail-cut behavior; the no-flush rule becomes meaningful only when a seamless wrap lands."

### 2.2 The seam, quantified **[measured]**

The negative-control spike test emulates the production discipline offline at the production constants (15 pulls past a 6000-frame loop end models the ≤33 ms tick latency; stop → reschedule → resume with content anchored `0.06 × 48000` frames into the fresh player timeline models `play(at: now + startLeadSeconds)`):

| Seam component | Measured | Source constant |
|---|---|---|
| Post-loop-end **overshoot** (wrong content audibly plays) | 1680 frames = **35.0 ms** (modeled worst case; live range 0–33 ms tick + quantum) | 33 ms playhead tick, AudioEngine.swift:1526 |
| **Silence gap** (queue cleared → anchored resume) | 2880 frames = **60.0 ms**, exact | `startLeadSeconds`, AudioEngine.swift:223 |
| Cycle-N+1 onset | frame 10560 == detection (7680) + lead (2880), exact | — |

Two consequences, both audible in beat-making:
1. **The gap itself** (~60 ms silence, preceded by up to ~35 ms of post-loop material — production `scheduleAll` schedules to project end, so whatever lies past the loop end sounds during detection).
2. **Groove drift**: the wrap restarts *at* `loopStartBeat`, so detection latency + lead-in are ADDED to every cycle. A 2-bar loop at 120 BPM (4.0 s) runs ~76–95 ms (≈2%) long per cycle — the loop cannot hold tempo against an external reference.

Plus the state damage per wrap: chain tails cut, PDC rings flushed, instrument voices killed (all §2.1) — a reverb tail audibly chokes at every cycle boundary.

---

## 3. The primitive, proven (L-0 spike results) **[measured]**

`Tests/DAWEngineTests/GaplessLoopSpikeTests.swift` — 4 tests, kept permanent, all green (suite total 2115/246). Signals are analytic counting ramps (unique value per frame at Float precision; cycle N strictly positive, cycle N+1 strictly negative — silence, staleness, or off-by-one cannot masquerade). Loop length 6000 frames is deliberately NOT a multiple of the 512-frame pull: the splice lands **mid-quantum** (offset 368).

1. **Pre-queued dual schedule** — two buffers anchored at 0 and 6000 on ONE player: **0 mismatches over 12 000 frames**, boundary samples `0.255999 → -0.5` (exact last-of-N → first-of-N+1), 0 NaNs. Sample-continuous, bit-exact.
2. **Same-file region re-queued** (the literal loop shape): ONE `AVAudioFile`, region [0, 6000) queued twice via `scheduleSegment` — pass 2 re-reads from frame 0 (**splice `0.255999 → 0.25` == ramp(0)**), 0 mismatches both passes, 0 leaks of the never-scheduled sentinel content past the region. The shared-read-cursor worry (one file object, two queued reads) is refuted for the sequential case.
3. **Queue-while-playing** (the top-up discipline): segment 2 anchored at 6000 was scheduled after 3072 frames of segment 1 had already rendered (margin 2928 frames ≈ 61 ms) — **0 mismatches**, identical splice. Control-thread enqueue onto a rolling player already has production precedent (`Metronome.topUp` enqueues click buffers from the playhead task while rolling, Metronome.swift:143–155).
4. **Negative control** — §2.2's numbers; also pins that the seam's shape is overshoot THEN silence THEN restart (not silence alone).

Conclusion: **AVAudioPlayerNode dual-scheduling is sample-continuous**, including mid-flight queueing, in the exact anchor convention production already uses (`AVAudioTime(sampleTime:atRate:)` player-relative — PlaybackGraph.swift:1672–1673; "player sample time 0 ≡ transport position `fromBeat`", PlaybackGraph.swift:1628–1629). No completion handlers are needed or wanted (the production rule stays: completionHandler nil by design, PlaybackGraph.swift:1684–1688) — pre-queue from the playhead task instead. **[AMENDED 2026-07-12, m14-a/L-1 measurement]**: pre-queue must be EAGER (≥ sounding-cycle + 2 — the player's queue always holds at least one full future cycle); the original "wrap-minus-margin" phrasing here is struck as measured-unsafe. See §8 failure modes 8–9 for the two AVAudioPlayerNode facts the L-0 spike did not cover.

---

## 4. Design options evaluated

### Option A (RECOMMENDED): wrap-aware schedule-ahead on the existing players

Everything stays on the control thread; the render thread sees exactly the structures it sees today. Per loop cycle k, eagerly ahead (**[AMENDED 2026-07-12]**: "at wrap-minus-margin" is struck — measured-unsafe per §8 modes 8–9; the former parenthetical "or eagerly, one cycle ahead" is now the ONLY safe form, strengthened to +2 cycles):

- **Audio clips**: `scheduleAll` grows a loop window — segments intersected with `[loopStartBeat, loopEndBeat)` (the region-window truncation machinery already exists: "the region window truncates or under-fills the file", PlaybackGraph.swift:1632–1633), anchored at `round((k·loopSeconds + clipStartSecInCycle) · fileRate)` — an ABSOLUTE per-cycle integral, no cumulative rounding drift. Fade pieces re-use their baked buffers every cycle (identical windows; buffer re-enqueue is the Metronome precedent — "top-ups only enqueue existing buffers", Metronome.swift:14–15), so a wrap costs zero allocation after cycle 1.
- **MIDI**: `MIDIEventSchedule.buildEvents` is pure main-actor math (PlaybackGraph.swift:1765–1775); unrolling = build per cycle with `fromBeat: loopStartBeat` and event times offset by `k·loopSeconds·rate`, appended in sort order. The schedule shape already supports everything the seam needs: events are one flat sorted array against ONE anchor (MIDISchedule.swift:19–34), note-offs may land past the cycle boundary (tails ring through the seam), and same-pitch overlap across the seam is legal by contract ("same-pitch overlaps are legal: noteID pairs ons with their offs", MIDISchedule.swift:64). What must be ADDED: a republish re-seek — today a new generation resets the cursor to 0 and late events "ride along" (InstrumentSourceNode.swift:219–224, 256–259), which would re-fire the entire past on an extension republish. Adopt the AutomationSchedule discipline ("render side re-seeks its cursors on change", AutomationSchedule.swift:62; binary `seek`, AutomationSchedule.swift:192–200) with the note-safety law of §9-C2.
- **Automation**: unroll breakpoints per cycle via the same `buildBreakpoints` math (AutomationSchedule.swift:120–136); the renderer already re-seeks on generation change (AutomationRenderer.swift:187–189). The value at `loopEnd → loopStart` may step — that IS loop semantics, the same class as a `.hold` step today; no ramp-continuity work in v1.
- **Metronome**: unroll clicks per cycle (`scheduleClicks` over the loop window with per-cycle second offsets; barline math via the existing `meterMap.barBeat`, Metronome.swift:113–121). `topUp` generalizes from beats to cycles.
- **Playhead**: the anchor NEVER moves across wraps. `derivedBeats` (AudioEngine.swift:1500–1519) gains a modular branch: linear elapsed seconds → cycle k = ⌊elapsed′/loopSeconds⌋ and within-cycle seconds → beat via the map inverse **restricted to the loop window**. THE TIMELINE LAW: under an active loop, `loopSeconds = tempoMap.seconds(from: loopStartBeat, to: loopEndBeat)` and the map is only ever evaluated inside `[loopStartBeat, loopEndBeat)` — tempo segments past the loop end never leak into cycle timing.
- **Fallback**: any loop-bounds edit, tempo/meter-map edit, or track mutation while looping → the restart primitive, exactly today's behavior class ("Individual scheduled segments cannot be cancelled", AudioEngine.swift:1377–1378 — there is no un-queue). A seam on EDIT is honest; a seam every CYCLE is the bug.
- **Wire surface**: none. `transport.setLoop` (Commands.swift:413–420 → `ProjectStore.setLoop`, ProjectStore.swift:750–762 → `loopChanged` cache) is semantically unchanged; loop fields live in `TransportState` (Model.swift:1061–1066, min length 0.25 beats: Model.swift:1123, 1150).

**RT-safety: zero new render-thread code.** All unrolling is main-actor arithmetic; publishes ride the existing atomic slots. The only render-side change in all of M14 is the MIDI cursor re-seek (a bounded binary search per generation change — the automation renderer already runs exactly this on the render thread, AutomationSchedule.swift:192–200).

### Option B: dual-player ping-pong (two players per clip, alternate cycles)

The fallback if one-player queue-splicing had failed — it did not (§3). Costs double the player/node count, a second bake-buffer set, and a handoff protocol; buys nothing the spike didn't already prove for free. **Loses.**

### Option C: custom render-callback transport (sample-accurate looping below AVAudioEngine)

The escalation path (project law: prefer AVAudioEngine facilities until they measurably limit us). The spike measured the opposite of a limit: bit-exact continuity through the standard API. **Loses — no grounds to escalate.**

### Option D: keep the restart, tune the seam smaller

Shrink `startLeadSeconds`, tighten the tick. Fails structurally: the stop still clears queues (silence ≥ one quantum + scheduling latency), detection latency remains, tails/rings/voices still flush, and the per-cycle groove drift (§2.2) remains nonzero. Polishes the bug instead of removing it. **Loses.**

---

## 5. Continuity of stateful DSP across a seamless wrap

The decisive property of Option A: **the wrap stops touching the graph at all** — no `stopAllPlayers`, no flush family. Each stateful stage then behaves correctly BY OMISSION:

| State | Today at wrap | Under Option A | Work needed |
|---|---|---|---|
| Effect-chain tails (reverb/delay) | Cut (`requestResetAll`, PlaybackGraph.swift:1860–1865) | Ring through the seam — free and desirable | None (don't call the flush) |
| PDC compensation rings | Flushed (`armCompensationResets`, PlaybackGraph.swift:1866–1874) | History persists; the spec's no-flush rule activates exactly as that comment anticipated | None |
| Instrument voices | All-notes-off (`publish(nil)` + `requestFlush`, PlaybackGraph.swift:1846–1849) | Voices/releases ring through; scheduled offs straddling the seam fire at their natural times | Cursor re-seek law (§9-C2) |
| Sidechain key alignment (m12-f) | N/A (graph restarted anyway) | Key is a graph edge pulled same-quantum (`ChainHostAU` input bus 1: ChainHostAU.swift:23, 122, 250); nodes never stop → the same-frame law holds with zero work | None |
| Automation value at seam | N/A (rebuilt) | Steps to the loop-start value — correct loop semantics (same class as a `.hold` step) | Unroll only |
| Meter taps / analyzer | Taps go dark during the restart | Mixer nodes never stop (taps live on the strip mixer, PlaybackGraph.swift:94) → continuous | None |

The flush family REMAINS for real stops, seeks, and edits — `stopAllPlayers`' contract ("Every stop, seek, tempo change, loop wrap, tracksDidChange restart…", PlaybackGraph.swift:1840–1843) simply loses the words "loop wrap".

---

## 6. The four parked consumers — what each inherits

| Consumer | Inherits from this verdict |
|---|---|
| **Metronome toggle** (ProjectStore.swift:786–811) | Today it reuses seek/restart while playing, "costs the restart primitive's ~60 ms lead-in seam — acceptable v0 (documented tradeoff; gapless click toggling needs live player scheduling)" (ProjectStore.swift:792–797). Under Option A the transport never needs restarting: **disable** = `metronome.stop()` — its OWN player (Metronome.swift:33), clip audio untouched; **enable mid-play** = re-anchor the metronome player at "now" with `playerStartBeat` = current beat and schedule from the next integer beat (placement jitter = the documented ±1-frame live-anchor class, InstrumentSourceNode.swift:15–17). The ProjectStore seek fallback is retired in M14 phase L-3. |
| **Loop-cycle take recording** (M5 iii-b; "loop-cycle recording explicitly deferred", ROADMAP.md:71) | The enabler is the anchor NEVER moving across wraps: capture stays ONE linear take against one anchor — exactly why wrap is suppressed while recording today (AudioEngine.swift:1533–1535). Lane-per-cycle becomes pure store-side slicing of the linear capture at k·loopSeconds (the take-lane machinery exists). Zero capture-path changes; the suppression lifts only when iii-b lands on top of M14. |
| **F9 bypass-click** (EffectChainProcessor.swift:11–12: "v0 accepts the bypass-toggle click (hard swap); a short crossfade ramp is an additive later change inside the walk") | Inherits a NEGATIVE verdict: it is NOT the transport's seam. The fix is chain-local (the crossfade inside the walk, exactly as its own comment says) and must not piggyback restart machinery. Unparked, independent of M14. |
| **F9 stop-tails** (audit-m13.md:23, parked at audit-m13.md:112) | The most-hit case — tails cut every loop cycle — disappears entirely under Option A. Tail ring-out at a TRUE stop remains a separate optional polish (let the engine run briefly post-stop); unparked, small, orthogonal. |

**§6.1 — Unpark status (m14-d/L-4 addendum, 2026-07-12; M14 complete):**

- **Metronome toggle — DONE (L-3).** `metronomeChanged(_:)` engine intent: disable = click-player-local `metronome.stop()`; enable mid-play = re-anchor at now+lead from the modular beat (`metronomeElapsedOffset`). The ProjectStore seek fallback is retired (comment at the old site records it). Clip output byte-identical through a mid-play toggle — pinned by the L-3 A/B.
- **M5 iii-b loop-cycle take recording — UNPARKED, store-side follow-up.** The enabler (the never-moving anchor) is live. The recording suppression currently sits in TWO places, both of which iii-b must lift together: `AudioEngine.startPlayers(scheduleLoop:)` — the record path passes `scheduleLoop: false` so a take schedules linear — and the playhead task's `activeTake == nil` guard on the legacy wrap branch. Lane-per-cycle is then pure store-side slicing of the linear capture at k·loopSeconds. Zero capture-path changes required.
- **F9 bypass crossfade — UNPARKED, independent, chain-local.** Negative inheritance confirmed through L-1…L-4: not the transport's seam; the fix is the crossfade inside the `EffectChainProcessor` walk (its own comment says exactly this). Must not touch restart/loop machinery.
- **F9 true-stop ring-out — UNPARKED, optional polish.** The per-cycle tail cut died with the wrap flush (C5 live-measured); a TRUE stop still cuts tails via `stopAllPlayers` — deliberate. Letting the engine run briefly post-stop is a small orthogonal item, priority down to taste.

---

## 7. Offline/render parity

**Nothing changes offline — by design and explicitly.** The offline renderer does not loop and states so: "Looping is intentionally ignored here: the offline renderer produces one linear pass over `[fromBeat, fromBeat + duration)`. Loop wrapping is a live-transport concern" (OfflineRenderer.swift:28–30). All Option A machinery hangs off the live playhead task and live wrap path; `render.mixdown`, `render.stems`, and bounce (and their Σ-stems / byte-identity gates) see zero new branches. Condition C8 pins this with a null-case byte gate.

---

## 8. Failure modes

1. **Republish re-seek double-fire/drop** (the one new render-side behavior): an extension republish must not replay delivered note-ons nor skip pending note-offs. Contained by the APPEND-ONLY LAW (§9-C2): an extended schedule is the old event array + appended later events from the SAME anchor — prefix-identical by construction — and the re-seek lands on the first event ≥ the current render position. Unit-pinned per §9-C2. **[REFINED 2026-07-12, m14-b/L-2 — two realizations inside the intent]**: (a) "current render position" must be the DELIVERED WATERMARK (last delivered windowEnd), not the current quantum's renderStart — otherwise late-ride-along events after a skipped quantum get dropped; (b) generation alone cannot discriminate extension from restart (publishes coalesce) — an explicit `timelineID` carries the same-anchor law (same tid = extension → bounded re-seek; changed tid = restart → full reset). Also: append-only extension is a sorted MERGE, not a concat — straddling note-offs interleave with the next cycle's note-ons.
2. **Cycle-anchor rounding drift**: contained by computing every anchor from the absolute integral (`k·loopSeconds + offset`, never `previous + loopFrames`); pinned by C3's == placement gates (the m12-c exact-integral discipline).
3. **Short-loop starvation**: `minLoopLengthBeats = 0.25` (Model.swift:1123) at the 400 BPM cap = 37.5 ms/cycle ≈ one 33 ms tick — one-cycle-ahead is not enough. Contained by the horizon law (C6): schedule-ahead ≥ 2 tick periods, topping up MULTIPLE cycles per tick when needed (`scheduledThroughCycle` state, the Metronome `scheduledThroughBeat` pattern, Metronome.swift:46).
4. **Live jitter vs the offline proof**: the spike is offline; live players start on host-time anchors with the documented ±1-frame mapping jitter (InstrumentSourceNode.swift:15–17). But the splice itself is in the PLAYER-RELATIVE sample timeline (anchored segments on an already-rolling player) — host time is not consulted at the wrap, so continuity holds live by construction. Still gated live by C5's tap-capture check, not assumed.
5. **Loop edit inside the horizon**: queued segments can't be cancelled → restart fallback (C7 pins ONE seam, no stale leftovers). `transport.setLoop` wire semantics unchanged.
6. **Memory growth**: fade-piece buffers are cached and re-enqueued, not re-baked; the retire-bin lifetime rules (InstrumentSourceNode.swift:90–93) cover republish churn. **[CORRECTED 2026-07-12, m14-b/L-2]**: the original claim "bounded by the horizon — single-digit cycles; no unbounded structure exists" is WRONG for MIDI/automation under the append-only-from-the-same-anchor law — `scheduledThroughCycle` is monotonic, so event/breakpoint arrays grow with TOTAL CYCLES PLAYED (~24 B/event/cycle; an hours-long dense loop session reaches tens of MB, and each extension re-copies the array). L-2 implemented the law as written (correctness first). **[DECIDED 2026-07-12, m14-d/L-4] — containment = PRUNE-BELOW-WATERMARK on the SAME timelineID; the append-only law is refined to THE SUFFIX-IDENTITY LAW.** An extension republish on an unchanged `timelineID` may, in addition to appending strictly-future events, REMOVE events with `sampleTime <` a prune bound **P**, provided P ≤ every delivered watermark the render side can hold when it adopts the new schedule. The re-seek invariant is preserved because the renderer re-seeks BY VALUE, never by index — `lowerBound(events, deliveredThrough)` (InstrumentSourceNode step 3): for any watermark w ≥ P, the pending suffix `{e | e.sampleTime ≥ w}` is IDENTICAL in the pruned and unpruned arrays, so no delivered event re-fires (everything below w is delivered by definition) and no pending event — late-ride-alongs and straddling note-offs included — is dropped (nothing at/above P is removed; pruning is TIME-based, not provenance-based, so an old cycle's straddling off that lands past P survives). **P is safe by construction**: P = the absolute-integral start frame of cycle `soundingCycle − 1`, where `soundingCycle` comes from the control thread's render-clock snapshot that lower-bounds the render position — one FULL loop cycle of margin over the ±1-frame anchor-mapping jitter class, and the render position only moves forward between snapshot, publish, and adoption. **Trigger**: on the existing top-up cadence, when `(soundingCycle − 1) − prunedBelowCycle ≥ loopPruneThresholdCycles` (8) — containment publishes RIDE the normal extension republish (same tid, generation bump, no flush, no reset), so voices sounding across a containment boundary keep their pending offs untouched. **Automation** contains at the same seam by REBUILDING from `prunedBelowCycle` instead of cycle 0 (per-cycle blocks are self-contained — each re-states its entry value on its own first frame, so `value(t)` for every t ≥ P is unchanged; the head block drops once pruned; evaluation is position-absolute and cursors already re-seek on every generation change). Memory is thereby bounded at ~(threshold + margin + eager/coverage lookahead) ≈ a dozen cycles of events/breakpoints regardless of session length. **Rejected alternative — periodic tid rotation at a natural seam**: a CHANGED tid re-latches the offline epoch (shifting every remaining event by the elapsed render time — the exact defect the same-tid rule was built to prevent, AutomationRenderer.swift:195–211) and resets `deliveredThrough`, so exactly-once would then depend on the control thread reproducing the render thread's delivered set exactly — it can only estimate (the watermark is render-thread-only state), making rotation-without-flush a race by construction; fixing that would need NEW render-side surface (a conditional watermark carry-over), violating C4 for zero benefit over pruning. Pinned by the m14-d containment soak (≥ 2 containment events; array high-water bounded; C2 ledger exactly-once across containment; straddling voice across the containment boundary delivers its off at its natural frame, zero resets).
7. **Recording interaction**: the `activeTake == nil` suppression (AudioEngine.swift:1535) stays until M5 iii-b explicitly builds on the new primitive — recording behavior is bit-identical through M14.
8. **[ADDED 2026-07-12, m14-a/L-1 measurement] Drained-queue freeze**: an AVAudioPlayerNode inside the production strip chain whose queue fully drains (cycle content ends before the loop boundary — e.g. a short clip at the loop start) never sounds items queued after the drain, at ANY anchor lead (measured: 33 696 frames of lead, still silent; the identical scenario queued up-front plays exactly). A bare player → mainMixer does NOT reproduce this — it appears only inside the strip sandwich, which is why the L-0 spike missed it. Containment: the eager top-up law — `topUpLoopCycles` keeps every looping player's queue at ≥ sounding-cycle + 2, so a queue holding future content is never empty.
9. **[ADDED 2026-07-12, m14-a/L-1 measurement] Mid-flight lead threshold**: enqueueing onto a still-busy player needs ≥ ~2.5k frames of anchor lead for a bit-exact splice (whole item silently lost at ≤ 2048 frames of lead, partial-quantum drop at ~2300, clean at ≥ 2496; the L-0 spike's 2928-frame margin happened to sit just above the cliff). Containment: the same eager rule — every enqueue lands ≥ one full cycle (or ≥ horizon − tick) before its anchor. Without modes 8–9's rule, the C3/wrap/baked gates fail with these exact measured signatures.

---

## 9. Phased M14 implementation plan

**L-0 — the gating spike: DONE, kept, green** (`GaplessLoopSpikeTests`, 4 tests — §3). It remains a permanent regression pin for the splice primitive.
**L-1 — transport core** (AudioEngine + PlaybackGraph, control thread only): loop window in `scheduleAll`, per-cycle unrolled audio segments + baked-buffer cache, `derivedBeats` modular branch + timeline law, playhead-task top-up (`scheduledThroughCycle`), wrap path stops calling `restart`. Gates: C1, C3, C6, C8.
**L-2 — MIDI + automation unroll**: append-only builders (per-cycle `buildEvents`/`buildBreakpoints` with second-domain offsets), InstrumentRenderer cursor re-seek on generation change (AutomationSchedule.seek pattern). Gates: C2; straddling-note and same-pitch-across-seam fixtures.
**L-3 — metronome + toggle**: click unroll across cycles; gapless metronome enable/disable via metronome-player-local stop/re-anchor; retire the ProjectStore seek fallback (ProjectStore.swift:792–797 comment updated). Gate: toggle mid-play leaves clip output byte-identical in an offline-driven A/B.
**L-4 — live gates + docs**: live E2E wrap with tap capture (C5: tail crosses the seam; no zero-run at the boundary), loop-edit fallback test (C7), ARCHITECTURE.md restart-primitive/§stopAllPlayers contract updates, unpark notes for the four consumers.
**Deferred, recorded**: M5 iii-b loop recording (store-side, after L-1..4); F9 bypass crossfade (independent, chain-local); F9 true-stop ring-out (optional polish).

---

## 10. Recommendation

**GO-WITH-CONDITIONS.** Numbered, falsifiable:

1. **C1 — L-0 stays green.** The spike suite is permanent; any splice regression (OS update, format change) blocks M14 work that day. *(Already satisfied: 4/4 green 2026-07-12, suite 2115/246.)*
2. **C2 — MIDI republish law**: schedule extensions are APPEND-ONLY from the same anchor; across any republish, every noteID delivers its on exactly once and its off exactly once (unit test republishing mid-render; violation = drop to per-cycle full-restart of the MIDI side only, and return here). **[REFINED 2026-07-12, m14-d/L-4]**: append-only holds ABOVE the delivered watermark; below it, the §8.6 containment rule may prune (the suffix-identity law) — the exactly-once ledger is the invariant, and it holds verbatim across containment events.
3. **C3 — cycle-placement exactness**: for ≥ 3 unrolled cycles under a multi-segment tempo map, every audio anchor and MIDI event frame == the absolute integral, pinned with == (the m12-c discipline). Any `previous + loopFrames` accumulation found in review is a defect.
4. **C4 — zero new RT surface** beyond the bounded cursor re-seek; no allocation, locks, or ObjC on the render path; any deviation returns to this note for amendment.
5. **C5 — the wrap does not flush**: live tap capture across a wrap shows a chain tail crossing the seam and no zero-run at the boundary; chains/PDC rings/voices persist. The flush family still fires on stop/seek/edit (pinned both directions).
6. **C6 — horizon law**: schedule-ahead ≥ 2 playhead-tick periods; a 0.25-beat loop at 400 BPM sustains N ≥ 20 cycles with no starvation gap.
7. **C7 — edit fallback**: a loop-bounds edit mid-loop produces exactly ONE restart seam and no stale queued segments from the old bounds.
8. **C8 — offline null-case**: a non-looping project renders byte-identical (SHA) before/after M14 lands; `render.stems`/bounce gates (Σ ≤ 1e-4, byte-identity) unaffected — the loop machinery must be provably invisible offline.

Failure of C1 at any point converts this to NO-GO/park with the spike retained as evidence (the m10-p precedent). No new environment requirements: everything runs offline from bare SPM; no full-Xcode dependency.
