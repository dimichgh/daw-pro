# m19-f design flight — birth-latency riders R1 + R2 (m18-c cost model)

**Author**: daw-architect. **Date**: 2026-07-16. **Status**: DESIGN COMPLETE — zero code changes in this flight; this document is the implementation prescription for audio-dsp-engineer.

**Context**: m18-c (ROADMAP.md:282) established the honest cost model for mid-play rebuild/resume: **~140 ms core + ~6 ms × rolling-clip-player count (+ ~1 ms/player quiesce)** — `AVAudioPlayerNode.play(at:)` costs 5.4–6.1 ms per call (one render-quantum handshake, blocking the CALLER), and `stop()` ~1 ms per player. The 143→390 ms "growth" was recipe player-count, not class growth. R1/R2 were filed there verbatim; m19-f (ROADMAP.md:302) routes R2's semantic question here first.

---

## 0. Verdicts (top line)

| Rider | Verdict | One-line reason |
|---|---|---|
| **R1** — skip play/stop handshakes for empty-schedule players | **GO** | The skip predicate is exactly "zero enqueues since last stop", trackable with one main-actor flag; no in-tree path can ever deliver sound to a started-empty player anyway (they are pure waste today), and every path that later gives a player a schedule already routes through a full re-anchored restart. |
| **R2** — batch/parallelize the serial `play(at:)` loop | **NO-GO as filed** (concurrency form). Superseded by **R2′**: a past-anchor semantics probe + a conditional player-count-scaled anchor lead. | Cross-instance `play(at:)` concurrency is undocumented, with two adverse in-repo priors (m18-d's process-global AudioToolbox state crash class; m16-a's play-raise class), and its win is speculative (AVFAudio likely serializes internally on the render-command seam). Meanwhile the R2 alignment review surfaced a REAL, latent defect: at high active-player counts the serial loop overruns the 60 ms anchor lead and — per the SDK header's documented past-anchor behavior — late players start with a SHIFTED timeline, silently breaking lockstep. The deterministic fix is a scaled lead, not concurrency. |

The m19-f roadmap GATE ("per-player slope collapse for IDLE players; alignment suite green") is R1-shaped and is fully carried by the R1 GO.

---

## 1. The alignment contract as found in code

### 1.1 How the shared anchor is computed

`AudioEngine.startPlayers(fromBeat:tempoMap:countInBars:renderClockTrusted:)` — `Sources/DAWEngine/AudioEngine.swift:1805-1881` — is the ONLY live start/resume primitive. Order inside one roll:

1. `graph.scheduleAll(fromBeat:tempoMap:loop:)` (:1824) — every clip's segments enqueue on its own player in **player-relative sample time**.
2. If looping, `graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)` (:1829-1831) — cycles 1–2 pre-queue on the SAME players, still before start.
3. `graph.prepareAllPlayers(withFrameCount: 8_192)` (:1832).
4. ONE anchor is minted for the whole roll (:1840-1859 trusted render clock; :1863-1880 host-clock fallback used by the rebuild-resume path, `renderClockTrusted: false`):
   - `anchorHost = outputNode.lastRenderTime.hostTime + hostTicks(startLeadSeconds) [+ countInTicks]`, with `startLeadSeconds = 0.06` (`AudioEngine.swift:311`), or `mach_absolute_time() + lead` in the fallback.
5. `graph.startAllPlayers(at: AVAudioTime(hostTime: anchorHost))` (:1859 / :1876) — the serial loop, `PlaybackGraph.swift:2728-2743`: `forEachClip { … node.player.play(at: anchor) }` under the m16-a per-node `isPlayable` guard (:2647-2650) + per-node ObjC exception barrier (:2733-2742).

Per-clip anchor math (`scheduleAll`, `PlaybackGraph.swift:2023-2061`): a clip starting at transport beat `b` on a roll from beat `B` anchors its first piece at player-sample `whenSample = max(0, seconds(B→b)) × fileRate`; a clip already sounding at `B` anchors at **player time 0** with its file offset advanced. Loop cycles use the absolute-integral law `headSeconds + (cycle−1)·cycleSeconds + anchorOffsetSeconds` (:2452-2459).

### 1.2 What guarantees mutual sample-accuracy

**The anchor VALUE alone — not call ordering — and only within the lead window.** Every player receives the identical `AVAudioTime(hostTime: anchorHost)`; each independently maps its player-timeline zero to that host time, so calls may complete in any order **provided each `play(at:)` executes before the anchor host time arrives**. Nothing in the code path depends on loop order; nothing reads back `playerTime`/`isPlaying` anywhere in DAWEngine (grep-verified 2026-07-16) — the transport clock derives exclusively from `outputNode.lastRenderTime` vs the stored `PlaybackAnchor` (`AudioEngine.elapsedSeconds`, :1946-1957).

**The documented boundary of that guarantee** (macOS 26.5 SDK, `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AVFAudio.framework/Versions/A/Headers/AVAudioPlayerNode.h:323-324`, verbatim):

> "Note that providing an AVAudioTime which is past (before lastRenderTime) will cause the player to begin playback immediately."

The plain reading: a late `play(at:)` call does NOT retroactively anchor — the player's timeline zero becomes its ACTUAL start, and every segment it has queued (anchored in player-relative samples) plays **shifted late by the lateness**. Combined with the m18-c measurement (startAll = 236 ms at 40 players against a 60 ms lead), this means **today's lockstep contract is already broken at scale for ACTIVE players**: on a 40-active-player resume, roughly players 10+ start after the anchor has passed, and the last player's audio runs ~170+ ms behind the grid for the REST OF THE ROLL. The m18-c gates could not see this — the recipe was 40 steady 440 Hz tones judged by peak/RMS, which is insensitive to per-track time shifts. This is a latent finding this flight files formally (see §3, R2′), with one honesty caveat: the header sentence is ambiguous between "timeline zero = now" (shifted schedule) and "begins output now against the past anchor" (retroactive, elapsed content skipped, aligned join). The R2′ probe (§3.3) pins which one this OS actually does before any lead surgery lands.

### 1.3 What happens to players whose schedule is empty

`scheduleAll` enqueues NOTHING for a clip whose region is entirely behind the roll start (`frameCount ≤ 0` / `sourceStart ≥ fileLength` guards, :2055-2058) or at/past the loop end under a live loop (:2049-2053). `buildCyclePlan` likewise returns nil for non-contributors (:2257-2260). But `startAllPlayers` walks ALL ClipNodes (:2728) and starts every playable one — an empty-queue player is started, renders silence, and pays the full ~6 ms handshake; `stopAllPlayers` (:2801-2804) later pays ~1 ms to stop it. Two decisive facts about these started-empty players:

- **Nothing can ever deliver sound to them mid-roll.** The only mid-roll enqueue path is `enqueueLoopCycle` (:2452-2474), restricted to `loopUnroll.clipPlans` — built pre-start (:2218-2231) and guaranteed non-empty-scheduled by the initial `topUpLoopCycles(elapsed: 0)` at `AudioEngine.swift:1829` (every plan's cycle-1/2 first piece carries an anchor, `items` is never empty — worst case `[plainSegment]`, :2263-2264, :2297, :2346).
- **Even if something tried, it would not sound**: the m14-a LoopPrimitiveProbe pinned that a playing player whose queue fully drains FREEZES — items enqueued after the drain never sound at any anchor lead (documented at `PlaybackGraph.swift:2360-2374`). A started-empty player is in exactly that state from its first quantum. Leaving it STOPPED is strictly more capable than today (a stopped player can always be scheduled + started fresh next roll).

### 1.4 How a mid-play clip addition gets its player started today

There is **no incremental join path anywhere in the tree**. Every schedule-affecting change converges on a full re-anchored roll:

- Clip add/edit on an existing strip: `reconcile` builds the ClipNode (attach + connect, `PlaybackGraph.swift:777-782`), returns `changed = true` → `AudioEngine.tracksDidChange` :722-726 → `restart(fromBeat: derivedBeats(), …)` (:1767-1771) = `stopAllPlayers` → `scheduleAll` → `startAllPlayers(NEW anchor)`. ALL players re-anchor together.
- Track/send birth mid-play (the m18-c scenario): reconcile announces → `needsEngineRebuild` → `rebuildEngine` (:781-886) → quiesce + discard engine → cold build → `startPlayers(resume.beats, renderClockTrusted: false)` (:878-885). Again a whole-roll re-anchor.
- Seek, tempo, loop-bounds, loop-enable-mid-play (:2036), config recovery: all route through `restart`/`startPlayers`.

So "how does a skipped player get its start when it later gains a schedule" has a structural answer: **through the same restart that gave it the schedule**, with the skip predicate re-evaluated fresh every roll. The invariant R1 must preserve (and assert) is: *no code path may ever call `play(at:)` on a single player against a PREVIOUS roll's anchor.*

**The join math, stated for the record** (required if anyone ever builds in-place clip birth): to join a live roll (anchor host time `A`, roll start beat `B`, tempo map `M`) sample-accurately, a single player must pick a FUTURE host time `F = now + lead`, compute the transport beat at `F` — `B_F = M.beat(from: B, elapsedSeconds: hostSeconds(F − A))` — then run the standard `scheduleAll` per-clip math **as if the roll started at `B_F`** (file offset advanced for already-elapsed content) and call `play(at: AVAudioTime(hostTime: F))`. Joining with the ORIGINAL past anchor `A` is structurally unreliable per §1.2: the player would start "immediately" at an unknowable quantum boundary, shifting its whole schedule. Today no such path exists; the restart primitive is the join primitive.

---

## 2. R1 — skip the handshakes for empty-schedule players: GO

### 2.1 Q1 — the precise definition of "empty schedule"

> **A ClipNode is schedule-empty iff its player has received ZERO `scheduleSegment`/`scheduleBuffer` calls since that player's last `stop()` (equivalently, since ClipNode creation).** Evaluated at `startAllPlayers` time — i.e., after the head pass AND the pre-start loop top-up have both run.

This is the **enqueue ledger itself**, not a model-level heuristic. Deliberately NOT "no clips on the timeline" and NOT "no segments in the transport window" — those re-derive scheduling decisions and would drift from the six real enqueue guards (frame-count truncation, loop-end truncation, file-length clamp, stretch-pending skip, file-open failure, bake fallbacks). The ledger definition automatically classifies every case correctly:

| Case | Schedule-empty? | Why |
|---|---|---|
| Clip entirely behind the roll-start beat | YES | `frameCount ≤ 0` guard, no enqueue (:2055-2058) |
| Clip at/past loop end under a live loop | YES | window truncation + `buildCyclePlan` nil (:2049-2053, :2257-2260) |
| Clip behind playhead but inside the loop window | **NO** | cycle-1/2 segments pre-queue at `topUpLoopCycles(elapsed: 0)` before start (§1.3) |
| Bake-failure fallbacks (envelope/fade) | NO | fallback still enqueues the plain segment (:2602-2606, :2140-2143) |
| Stretch-pending / file-open-failed clip | n/a | no ClipNode exists at all (:765-774, :785-816) |

### 2.2 Q2 — safety of leaving the player un-started, and the later-gains-a-schedule path

Safe, and strictly better than today, by §1.3–§1.4: a started-empty player renders silence, can never receive soundable content mid-roll (clipPlans exclusion + the drained-queue freeze), and every path that later gives the player a schedule already routes through `restart`/`rebuildEngine` → fresh `stopAllPlayers`/`scheduleAll`/`startAllPlayers` with a NEW shared anchor — where the flag is set by the new enqueues and the player starts in lockstep with everyone (anchor math of §1.1 verbatim; no special-case join math needed or permitted). The m18-c birth scenario itself IS this path.

### 2.3 Q3 — stop/rebuild with never-started players

`stopAllPlayers` (:2801-2804) may skip `player.stop()` exactly when the flag is false: flag false ⇒ zero enqueues since last stop ⇒ queue already empty AND (under R1) play was never called ⇒ the player is not playing and its timeline is already reset — `stop()` would be a semantic no-op costing ~1 ms. Critical asymmetry: **the skip predicate is the ledger flag, NOT "was started"** — a player whose `play(at:)` RAISED under the m16-a barrier (or was isPlayable-skipped) has flag=true and a non-empty queue; its `stop()` MUST still run to clear the queue (the reschedule primitive's contract, header `stop` discussion). One flag serves both sides because under R1, `play` is called iff the flag is true (modulo those failure skips, which keep flag=true and therefore still get stopped). Teardown paths stay unconditional: reconcile's remove/re-key `clipNode.player.stop()` (:742) and `rebuildEngine`'s engine discard are correctness seams, not hot paths.

### 2.4 The prescription (one implementation)

All in `Sources/DAWEngine/PlaybackGraph.swift`; control-plane/@MainActor only; **zero render-thread surface; no allocation/lock changes anywhere near the render path**. No full Xcode required (plain AVFAudio + SwiftPM/CLT).

1. **ClipNode ledger** (ClipNode, :62-88): add `private(set) var hasPendingSchedule = false` plus two funnel methods — the ONLY legal enqueue surface for clip players:
   ```swift
   func enqueueSegment(startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount, at when: AVAudioTime?) {
       hasPendingSchedule = true
       player.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount, at: when, completionHandler: nil)
   }
   func enqueueBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?) {
       hasPendingSchedule = true
       player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
   }
   func noteStopped() { hasPendingSchedule = false }
   ```
2. **Convert every clip-player enqueue call site** to the funnels — `scheduleAll` (:2095-2101, :2140-2143, :2157-2172), `scheduleEnvelopedPieces` (:2602-2606, :2614-2626), `enqueueLoopCycle` (:2463-2471). **Grep-zero gate**: `player.scheduleSegment|player.scheduleBuffer` in PlaybackGraph.swift outside the two funnels ⇒ 0 matches (the metronome owns its own player and is out of scope).
3. **`startAllPlayers`** (:2728): first guard, before `isPlayable`:
   ```swift
   forEachClip { node in
       guard node.hasPendingSchedule else { return }   // R1: nothing to play — no handshake, no notice
       guard isPlayable(node) else { postClipUnplayable(node); return }
       …existing barrier + play…
   }
   ```
   Behavior delta, deliberate: a disconnected clip with an empty schedule no longer posts `clip-unplayable` — it had nothing to play; the old notice was a false alarm. Audit any test pinning notice counts for behind-playhead clips.
4. **`prepareAllPlayers`** (:2676-2681): same first guard (skip the prepare call too).
5. **`stopAllPlayers`** (:2804): `forEachClip { node in if node.hasPendingSchedule { node.player.stop(); node.noteStopped() } }`.
6. **Anti-freeze tripwire** (the §1.3 invariant): at the top of `enqueueLoopCycle`, `assert(plan.node.hasPendingSchedule, "loop cycle enqueue onto a never-scheduled player — it would never sound (LoopPrimitiveProbe fact 1)")`. Debug-only; documents the law for future paths.
7. **Offline** (`OfflineRenderer.swift:343`, `startAllPlayers(at: nil)`): no special handling — a skipped player renders silence exactly as a started-empty player did; manual rendering ignores host times anyway (SDK header TIMESTAMPS rule 3). Byte-identity pinned by tests below.

Expected effect on the cost model: mid-play birth/resume ≈ **~140 ms core + ~6 ms × ACTIVE players + ~1 ms × ACTIVE players**, with idle players contributing ~0. The filed all-active recipe is unchanged (honest floor) — R1's win is real-project-shaped, exactly as the m19-f GATE demands.

### 2.5 Q4 — tests

Existing coverage that must stay green (the regression net): `EngineRebuildTests` (rebuild seam), `GaplessLoop*` suites (loop scheduling/cycles — they exercise the clipPlans path that must keep flags true), `PlaybackRenderTests`/`OfflineBufferRenderTests`/`StemNullTests`/`MixdownTests` (offline null/byte gates through `startAllPlayers(at: nil)`), `EngineNoticeEngineTests`/`MissingMediaNoticeTests` (notice families — audit for the §2.4-3 delta), `ExceptionArmorTests` (barrier), `TakeAlignmentEngineTests`. Plus the m16-a C1 ×10 gate and the m16-h 5/5 audible gate re-run at close (m18-c precedent).

New assertions (new file `Tests/DAWEngineTests/IdlePlayerSkipTests.swift`, offline/manual-render harness conventions from PlaybackRenderTests):

- **T1 — idle skip**: roll from a beat past clip A's end (clip B ahead); assert A's node `hasPendingSchedule == false` and `player.isPlaying == false` after start, B's true/playing (via `@testable` graph access).
- **T2 — the GATE's alignment case**: mid-play clip-add onto a previously-idle player lands sample-aligned — build session, roll past A, then add clip C on A's track at a future beat through the reconcile→restart seam; offline-render and assert C's first audible frame at the exact expected sample (same `==` conventions as the M1 sample-accuracy tests).
- **T3 — flag lifecycle across rolls**: roll 1 with player idle (skipped, and skipped by stop); roll 2 seeked before its clip (active); assert content sample-exact — proves the skip-stop left no stale state.
- **T4 — loop window inclusion**: clip behind the roll start but inside the loop window is NOT skipped (flag true pre-start) and sounds in cycle 1 (extends a GaplessLoopTransportTests case).
- **T5 — failure-path stop**: a node whose play was isPlayable-skipped (detached fixture) keeps flag true and gets its queue cleared by the next stop (schedule → stop → assert fresh roll's schedule not duplicated).
- **T6 — offline byte-identity**: bounce a range starting past clip A with A behind it: byte-identical output pre/post R1 (capture the pre-R1 reference before landing, or assert against the analytic expectation).

---

## 3. R2 — batch/parallelize player starts: NO-GO as filed; R2′ prescribed

### 3.1 Q5 — the alignment contract (answered from code)

Stated in §1.2: **anchor-value alignment, order-free, valid only for calls completing before the anchor deadline.** Ordering of the serial loop is provably irrelevant (shared immutable anchor; no inter-player data flow; no playerTime reads). What is NOT order-free is the deadline: with `startLeadSeconds = 0.06` and 5.4–6.1 ms/call, the loop overruns the anchor beyond ~10 active players, and every subsequent player enters the SDK-documented past-anchor regime (§1.2). So batching/parallelizing would not break the contract — the contract at scale is already broken by the serial loop's duration, and any fix must get every `play(at:)` completed (or every player's start honored) inside the lead.

### 3.2 Q6 — `play(at:)` cross-instance thread-safety: evidence status INCONCLUSIVE-NEGATIVE

Researched 2026-07-16; no authoritative statement exists either way:

- **Apple documentation/headers**: nothing on cross-instance concurrency. The only threading note in `AVAudioPlayerNode.h` (:71-76) concerns completion handlers: property access "requires some synchronisation between the calling threads internally", and player-node API calls from completion handlers "should be synchronised to the same thread/queue" — an instruction to SERIALIZE, offered without a cross-instance guarantee.
- **Apple Developer Forums thread 123540** ("AVAudioEngine thread-safety"): confirms `play()` blocks the caller proportional to the IO buffer duration; contains ZERO Apple-engineer guidance; developer consensus is "one serial queue for everything AVAudioEngine".
- **In-repo priors, both adverse**: (1) m18-d (ROADMAP.md:283) just proved AudioToolbox keeps **process-GLOBAL unlocked state** (DLS/SF2 engine) that crashes under two-thread interleaves — the fix was a serial queue; (2) m16-a proved `playAtTime:` RAISES NSExceptions under internal state races, and an ObjC raise through Swift concurrency frames is the poison this codebase spent a milestone exorcising. Betting on undocumented AVFAudio concurrency contradicts both records and the m18-c scope line "never trade RT safety for latency".
- **Win analysis even if safe**: the handshake blocks the caller awaiting the render-cycle seam; if AVFAudio serializes these on an engine-global command queue internally (the architecture the per-quantum handshake implies), N concurrent calls still take ~N quanta — full risk, zero win. If they coalesce per quantum, the win exists but is unprovable without betting shipped stability on it.

### 3.3 Q7 — the alternatives, evaluated

| Option | Alignment | RT-safety / crash risk | m16-a barrier interaction | Expected win @40 active players | Verdict |
|---|---|---|---|---|---|
| (a) Concurrent `play(at:)` via task group off main actor | OK in principle (order-free) IF all complete pre-anchor | Undocumented; two adverse in-repo priors (§3.2); NSException risk multiplied across N threads | Barrier fn is thread-agnostic ObjC `@try/@catch` (`ObjCExceptionGuard.m:3-14`) but the catch path (`postClipUnplayable`, noticeSink, skip bookkeeping) is @MainActor — requires collect-and-marshal; PlaybackGraph is @MainActor (:16), so player refs need `nonisolated(unsafe)` laundering (non-Sendable AVAudioPlayerNode) | UNKNOWN: ~10× if internally concurrent, ~0 if internally serialized | **NO** |
| (b) Scale the anchor lead so the serial loop finishes before the anchor | RESTORES lockstep at scale (the §1.2 defect's deterministic fix) — handshake blocks the CALLER only, so the render thread and the anchor wait are unaffected | Zero new surface; same serial main-actor loop, same per-node barriers | None — byte-identical loop body | No latency win (round-trip unchanged; the loop is the cost) — trades today's 60→240 ms smeared/SHIFTED re-entry for a uniform ~340 ms lockstep re-entry | **YES, conditional on the probe** (= R2′ leg 2) |
| (c) Pre-arm at prepare time so resume-time play is cheap | — | — | — | ~0: the handshake IS the play call's render-seam rendezvous; `prepare(withFrameCount:)` already runs pre-anchor (:1832) and prepays only decode. The inverted form (perpetually-playing players, schedule-only rolls) is structurally barred: `stop()` is the only queue-clear primitive (SDK header; the restart primitive's contract, AudioEngine.swift:1764-1766) and the drained-queue freeze (:2360-2374) makes an always-playing player a one-way trap | **DEAD** |
| (d) R1 alone bounds the practical cost | Unchanged for actives | Zero | Zero | Zero for the all-active worst case; collapses the typical case (most players idle at any playhead in real arrangements) | **YES — this is the ride** |

### 3.4 Q8 — R2 verdict and the R2′ prescription

**NO-GO on R2 as filed.** The concurrency form fails on evidence (§3.2), and its only unique benefit — compressing the all-active worst case — is the m18-c honest floor, already accepted. What the R2 review DID surface is the past-anchor lockstep break (§1.2), and that gets a deterministic, concurrency-free treatment:

**R2′ leg 1 — the past-anchor probe (mandatory, before any lead change).** A standalone live-device probe in the m16-h standalone-matrix tradition (a scripts/ or scratchpad CLT binary — NOT a suite member; hostTime anchors are ignored in manual rendering, so this cannot be an offline test). One engine, two players, shared future anchor `F`: player 1 `play(at: F)` before `F`; player 2 `play(at: F)` at `F + δ` (δ ≈ 100 ms); both schedule identical impulse-at-known-offset content anchored at player-sample 0; record via an output tap; measure the steady-state inter-player onset offset. Outcomes:
   - **Shifted-origin confirmed** (offset ≈ δ, the header's plain reading): today's >10-active-player resumes are misaligned → land leg 2.
   - **Retroactive anchoring** (offset ≈ 0, elapsed content skipped): late starters join the grid aligned after a private silence gap → today's behavior is acceptable; close R2 with the probe as the record, no lead change.

**R2′ leg 2 — player-count-scaled anchor lead (conditional on leg 1).** In `AudioEngine.startPlayers`, between `prepareAllPlayers` (:1832) and the anchor mint (:1840): read `let n = graph.startablePlayerCount` (new PlaybackGraph computed property: count of nodes with `hasPendingSchedule` — post-R1 this is ACTIVE players only) and replace the constant lead with
```swift
let lead = max(Self.startLeadSeconds, 0.02 + Double(n) * 0.008)   // 8 ms/player ≥ measured 5.4–6.1 + variance
```
used for `leadHostTicks` in BOTH anchor branches (:1840, :1866). Everything downstream inherits: `currentAnchor`, metronome (`clickAnchorHost` moves with it, :1846/:1862), count-in (additive, :1841/:1847), `derivedBeats`' negative-elapsed clamp already handles arbitrary leads (:1975-1976, :1953-1956). The metronome enable-mid-play re-anchor (:1416-1438) keeps the 0.06 constant — it starts ONE player. Properties: n ≤ 5 ⇒ lead stays 0.06 (null case byte-identical); n = 40 ⇒ 0.34 s uniform-lockstep re-entry replacing today's shifted smear; command round-trip UNCHANGED (the caller never waits for the anchor). Cap at 0.5 s and stderr-log if hit (a 60+-active-player session deserves a visible line, not a silent 1 s gap).

---

## 4. GATE re-shape — the m18c-orch scaling experiment

Source: `…/scratchpad/m18c-orch/orch-scaling.mjs` (verbatim contract: 41 audio strips fixed, K ∈ {10, 40} tone clips at beat 0, 5 mid-play `track.add` births per block, staging port 17695, kill-guard, bands: K=40 ∈ [330, 480], K=10 < 300, delta ∈ [120, 280]).

Re-shape for m19-f (new file `orch-scaling-idle.mjs` alongside a re-run of the original):

1. **ACTIVE control (original script, unchanged)**: all clips at beat 0, playhead ~0.6 s in — all K players active. Post-R1 expectation: bands HOLD verbatim (R1 changes nothing for actives; R2′ leg 2 does not move round-trips). This validates R1 didn't regress the measured model.
2. **IDLE variant (the GATE)**: same 41 strips and K clips at beat 0, but before each birth: `transport.seek` to a beat safely past every clip's end (tone440.wav is a short fixture; beat 64 at default tempo is conservative — assert the returned playhead), then `transport.play`, settle 600 ms, then the mid-play `track.add`. All K players are then schedule-empty at the resume. Bands:
   - `median(K=40, idle)` < 300 ms (falls out of the filed 330–480 class entirely);
   - `delta_idle = median(K=40) − median(K=10)` ∈ [−40, +60] ms — **the per-player slope collapse** (30 idle players × ~7 ms play+stop ≈ 210 ms of vanished cost, vs. host-variance noise);
   - K=10 idle ≈ K=40 idle ≈ the m13-class core + reconcile (~150–220 ms round-trip).
3. Keep every operational law from the m18-c close: staging 17695 never 17600, exact-PID kill, `.ips` counts before/after, summary line captured (never tail-piped), loop OFF, `project.new` normalize between blocks.

---

## 5. Risks

- **Ledger drift** (a future schedule path bypassing the funnels → a silently never-started active player): contained by the grep-zero gate (§2.4-2), the funnel-only convention comment on ClipNode, and T1–T4. Failure presentation would be honest silence on one clip, not a crash.
- **Notice-behavior delta** (§2.4-3): empty-schedule disconnected clips stop posting `clip-unplayable`. More honest, but any suite pinning notice counts must be audited (EngineNoticeEngineTests, MissingMediaNoticeTests, wire notice tests).
- **Offline byte-identity**: skipped vs. started-empty players both render silence; T6 pins it. If any downstream consumer someday reads clip-player `isPlaying` for UI, the skip becomes visible — grep-verified none exists today; the funnel comment records the invariant.
- **R2′ leg 2 UX**: high active counts trade immediate-but-wrong re-entry for delayed-but-lockstep re-entry (~340 ms at 40 actives). Musically correct is the right default for a DAW; the formula leaves ≤5-player sessions untouched. Watchdog unaffected (it watches render callbacks, not content).
- **Probe hazard**: the R2′ probe runs live audio on a device — keep it standalone (not in suites), m16-h precedent; it must not join CI.
- **What this flight deliberately does NOT do**: no concurrency anywhere near AVFAudio; no in-place mid-roll join primitive (the §1.4 math is recorded for the day a feature needs it, behind its own design flight).

## 6. Close-out bookkeeping (for the implementing agent, at landing — not this flight)

- Update `docs/ARCHITECTURE.md` "Sequencer clock: SETTLED" entry: (1) starts/stops are schedule-gated (empty-schedule players never start — R1); (2) the anchor-lead law (constant 0.06 for ≤5 startable players, 0.02 + 8 ms/player above, if R2′ leg 2 lands); (3) the probe-pinned past-anchor semantics, whichever way it lands.
- Tick the `- [ ] (m19-f)` ROADMAP checkbox with the measured before/after and the GATE numbers; record the R2 NO-GO + probe verdict verbatim.
- Re-run at close: full suites, m16-a C1 ×10, m16-h 5/5 audible, pins, plus both orch scaling scripts (§4).
