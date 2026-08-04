# m23-bs — `recoverEngine` steps the transport backward: design record

**Status:** design complete 2026-08-02 (`daw-architect`), implementation split into roadmap items
m23-bs-1 … m23-bs-4. Not settled until bs-2 lands and the continuity epsilon is measured.
**Primary file:** `Sources/DAWEngine/AudioEngine.swift`. No full Xcode required — no entitlements,
no AUv3, no signing.

⚠️ **NAMING — `docs/ROADMAP.md` IS AUTHORITATIVE.** The design was produced in two passes and its own
follow-up numbering **shifted between them** (pass 1: "bs-2" = other continuation sites, "bs-3" =
playhead continuity; pass 2: "bs-2" = other sites, "bs-3" = a mid-count-in WATCH). In the roadmap the
items are **bs-1** measure → **bs-2** mechanism → **bs-3** other continuation sites → **bs-4**
playhead continuity, with the mid-count-in issue filed as an observation rather than an item. Do not
cross-wire them; cite roadmap ids only.

⚠️ **This record was assembled from THREE design passes** (the architect was re-briefed twice with
new measurements). Everything below is the merged, current position. **§9.6 — the timing ceiling —
changed in every pass and is the one place to read carefully:** pass 1 said drop 1.2 → 0.4; pass 2
said 1.2 is not starvation-safe at all and the tightening must move to a different quantity; pass 3
refuted pass 2 and settled on 0.25. **The tiebreak was made by reading the source, not by taking the
latest pass** — the playhead task has no suspension point between `derivedBeats()` and
`playheadHandler?(beats)`, so a starved tick is late but internally consistent, and starvation costs
this metric sample COUNT rather than sample ACCURACY. Both withdrawn claims are kept named in §9.6,
because the second one is a natural and dangerous inference that a careful reader will re-derive.

---

## ⚠️ m23-bs-1 MEASURED THE SPLIT, AND IT MOVES THE TARGET — read this before §1

The design below was written before the measurement. **Its mechanism survives; its BUDGET is keyed on
the wrong term.** Measured 2026-08-02 by `audio-dsp-engineer` (m23-bs-1), verified by the orchestrator.

**1. The falsifier did NOT fire — the property witness argument stands.** Full-suite segment B is
**0.4–20.2 ms** (median 0.7 over 12 samples): the tens-of-ms side, not seconds-scale. The worst
sample is the strongest evidence and is not buried — 20.2 ms sits *inside* m23-bu-1's measured
OS-level queue-jitter band (18–98 ms) and three orders of magnitude below its main-actor scheduling
gaps (1803 / 3783 / 4218 ms). B's tail is OS-jitter-class, which is exactly and only the channel a
synchronous main-actor block is exposed to. §9.1's argument holds **by mechanism, not just by
magnitude**.

**2. ⚠️ THE DECISION RULE ROUTES WRONG, AND THE RULE IS THE THING AT FAULT.** Mechanically B fails
both clauses (filtered max 10.3 ms, full-suite max 20.2 ms; spreads 9.7 / 19.8 ms), which routes to
"adaptive budget justified". **Do not take that branch on that reasoning.** B is ~**1 %** of the
defect in every sample, it does not scale with the project — the 32-clip project reads *lower* than
the 1-clip one (0.6–1.9 vs 0.7–10.3 ms filtered) — and its spread is preemption of a synchronous
block. **A budget sized off B, fixed or adaptive, is sized off noise.** The rule was written before
anyone knew which term dominated; it asked the right question about the wrong quantity.

**3. THE TERM THAT ACTUALLY DOMINATES IS THE ANCHOR LEAD.**

| term | 1 clip | 32 clips / 16 players | shape |
|---|---|---|---|
| **lead** | **0.060 s** | **0.148 s** | deterministic; scales with pending AUDIO players |
| A (non-bounce) | 0.0002–0.0003 s | 0.005–0.017 s | scales with track count |
| A (bounce: prepare+start) | 0.0009–0.048 s | 0.028–0.041 s | 50× range, undecomposed |
| B | 0.0006–0.0103 s | 0.0006–0.0019 s | flat, ~1 % |
| residual | 0.0142 s | 0.0140 s | constant across everything |

Measured backward step: 0.079–0.084 s (1 clip, recover-only) to **0.207–0.215 s** (realistic,
watchdog). **The lead is ~75 % of it.**

**4. ⚠️ A CIRCULARITY bs-2 MUST SOLVE, and it is structural rather than a detail.** The lead is
computed from `graph.startablePlayerCount` (`AudioEngine.swift:3088`), which is only correct AFTER
`scheduleAll` (`:3056`) — and `scheduleAll` needs the beat. So **beat → schedule → player count →
lead → anchor** is a cycle: the beat must be committed before the lead is knowable, and the lead is
the biggest part of the interval the beat must be derived for. `startPlayers` also clears
`loopContext` at `:3042` on the way in, so the derivation cannot simply move inward either. Either
the caller predicts the pending-player count too, or the anchor contract carries the lead back out.
**`lastStartLeadSecondsForTesting` — landed by bs-1 — is exactly the feedback seam for predicting
it.** So the adaptive path survives, keyed on the LEAD rather than on B.

> **A resolution the orchestrator proposes for bs-2 to evaluate, because it makes the prediction
> nearly exact rather than heuristic:** the lead is a function of `startablePlayerCount`, and for a
> CONTINUATION *the project has not changed between the outgoing start and the recovery* — same
> tracks, same clips, same players. So the **previous start's own measured lead is not an estimate of
> the next one, it is very nearly the same number**, and the feedback path is a lookup rather than a
> forecast. That is a much stronger position than "predict the residual work", and it is available
> precisely because this is a continuation. ⚠️ **The exception is the one continuation site where the
> project DID change** — the rewire resume (`tracksDidChangeBody`), which runs *because* tracks
> changed and can therefore alter the player count. That site is bs-3, not bs-2, but the contract
> must not assume constancy in a way that silently breaks there; clamp-forward already bounds the
> miss, and this is the case that proves clamp-forward has to stay.
>
> Concretely, deriving after segment A gives `H = now + B + lead` with B ≈ 1 ms and lead ≈ 0.06–0.148 s
> — i.e. **the prediction is essentially "the previous lead", and everything else is noise.**

**5. ⚠️ THE RESIDUAL IS NOT A CONSTANT TO HARDCODE.** 12.0–17.4 ms across 20 filtered recovery
samples, invariant to project size AND to whether the engine bounced. It matches this machine's
output buffer to three decimals: `bufferFrames 512 @ 48 kHz = 10.67 ms` + `presentationLatency
1.3 ms` = **12.0 ms**, the band's floor. A read-only sweep of every output device present (BlackHole
2ch, MacBook Pro Speakers, ZoomAudioDevice) shows all report 512 frames, so no second data point
exists without WRITING a buffer size to the user's hardware — correctly refused as out of scope.
**bs-2 must DERIVE this term from `presentationLatency` + buffer duration, never inherit "13 ms".**

**6. Corrections the implementer made to its own earlier reporting, kept because they are the
honest part.** The "warm HAL" explanation for segment A's bounce half is **wrong** — full-suite
watchdog A is ~1 ms on one clip but ~44 ms on the realistic project under identical load; graph size
and device warmth overlap and these seams cannot separate them, so it is reported as a range. And
full-suite `measuredStep`/`residual` are **indicative only**: the playhead publishes 20–23
samples/leg filtered but 0–4 under full suite, with 5 of 18 full-suite legs printing
`⚠️STARVED(step-unreadable)`. The seam values (A/B/lead) are host-clock deltas taken inside the
engine and are unaffected — which is the property-witness principle paying off inside the
measurement itself.

**7. A correction to the ORCHESTRATOR's numbers.** My five-run bands (0.119–0.125 / 0.268–0.269 /
0.362–0.383) were used as the behaviour-neutrality gate. An A/B with a surgically-stubbed build
showed excursions past those bands in **both** arms — so **the bands were 5-sample artefacts**, not a
property of the tree, and "still inside the bands" was never the right neutrality test. The
instrumentation is neutral; my ruler was too short.

## The defect

`recoverEngine()` (`AudioEngine.swift:3292`) derives its resume beat from the host clock at ENTRY,
then does all the recovery work, then calls `startPlayers(...)` at `:3338`. Everything that work
costs is time the transport never accounts for, so the playhead resumes BEHIND where the music
actually was. Filed by the m23-bq close; not the m23-bq defect and not introduced by its fix — it
was masked by a freeze an order of magnitude larger.

### Measured (orchestrator, five consecutive `./scripts/test.sh --filter RecoveryPlayheadTests`)

| leg | 5 runs (beats of lag) | spread | net of control |
|---|---|---|---|
| CONTROL (no restart) | 0.124 / 0.119 / 0.125 / 0.124 / 0.121 | 0.006 (~3 ms) | — |
| RECOVER-ONLY (engine still running) | 0.269 / 0.268 / 0.268 / 0.268 / 0.268 | **0.001 (~0.5 ms)** | **0.145 (~72 ms)** |
| RESTART (watchdog) | 0.383 / 0.367 / 0.362 / 0.363 / 0.377 | 0.021 (~10 ms) | **0.259 (~130 ms)** |

**Two findings from this table drive the whole design.**

1. **The recover-only leg skips `engine.prepare()`/`start()` entirely** (the `if !engine.isRunning`
   guard at `:3309`) and still loses 72 ms. So the engine restart is only ~57 ms of the 130, and the
   MAJORITY of the defect is the other work — including the schedule pass INSIDE `startPlayers`,
   which is downstream of the point where the beat has already been committed.
2. **Filtered, this leg is essentially deterministic** (recover-only reproduces to 0.001 beats). That
   is a completely different regime from the full-suite starvation m23-bu-1 characterised, and it is
   why a tightened ceiling is arguable at all — see §9.

---

## §1 The decision

**Predict the anchor instant, derive the resume beat for that instant, and clamp the anchor FORWARD
if the start work overruns.** Three composing changes:

- **(a)** Move the resume derivation as late as possible — `recoverEngine` computes a *separate*
  resume beat immediately before `startPlayers`, after all of segment A. This eliminates segment A
  exactly rather than estimating it, and segment A contains `engine.start()`, the least predictable
  term.
- **(b)** `startPlayers` gains a required `anchorPolicy: StartAnchorPolicy` — `.asSoonAsPractical`
  (relocation, today's behaviour verbatim) or `.atHostTime(UInt64)` (continuation: "`fromBeat` was
  derived FOR this instant"). Segment B is thereby *covered* rather than left standing: the beat
  committed to `scheduleAll` and the instant the anchor lands become two views of one chosen number.
- **(c)** On overrun, clamp the anchor FORWARD, never backward — degrade to today's behaviour with an
  error equal only to the *prediction miss*, increment a counter, write a stderr note.

**(c) is load-bearing:** you never hand `startAllPlayers` a past anchor, so the m19-f shifted-origin
hazard is unreachable by construction.

---

## §2 The invariant, stated formally

`scheduleAll` (`PlaybackGraph.swift:2391`) computes every clip's player-time offset as
`tempoMap.seconds(from: startBeats, to: clip.startBeat)` (`:2403`) **and** stages the automation
timeline origin `stagedAutomationStart = (startBeats, tempoMap)` (`:2397`). `startAllPlayers(at:)`
establishes player-time 0 at `anchorHostTime`. `PlaybackAnchor(startBeats:anchorHostTime:)` asserts
the same thing for the playhead. So:

> **`startBeats` is the beat that occurs at `anchorHostTime`** — for the clip schedule, the automation
> origin, the metronome, the reference track, and the playhead, all at once.

The pair is not separable. It is not only the playhead that desyncs if `startBeats` is re-derived
after the schedule is built — **the automation origin desyncs too.**

The defect is that recovery satisfies the identity for the WRONG INSTANT: it computes
`startBeats = trueBeat(t_entry)` and publishes `anchorHostTime = t_entry + workA + workB + lead`.

**The one lever.** `startBeats` must be committed before `scheduleAll`; `anchorHostTime` is only
knowable after it. That is a fixed point with exactly two directions: fix the beat and derive the
instant (the instant is then in the PAST — unusable), or fix the instant and derive the beat
(prediction). Only the second is available. Everything else is about bounding the prediction error
and making the bound visible.

---

## §3 Alternatives that lose

### 3.1 Re-derive `beats` immediately before `startPlayers` (the roadmap's originally filed shape)

A strict subset of the recommendation — change (a) without (b) or (c). Not wrong, **incomplete**. It
removes all of segment A (including the ~57 ms of prepare+start) and **none** of segment B.

Condemned by the scaling, not just the constant: `scheduleAll` iterates every clip
(`PlaybackGraph.swift:2398`); `prepareAllPlayers(withFrameCount: 8_192)` (`:3084`) pre-decodes 8192
frames per player with a pending schedule; the serial start loop is 5.4–6.1 ms/player (m18-c, cited
at `AudioEngine.swift:3006`). **The measured fixture is ONE track, ONE clip.** A 40-clip project's
segment B is a different order of magnitude. So the filed shape fixes the constant term, leaves the
term that grows with the user's project, and makes `RecoveryPlayheadTests` go green enough to look
fixed on a one-clip fixture.

**The verification consequence is worse than the correctness one.** Under the filed shape the residue
is load- and project-dependent, so any tolerance set on it is a guessed millisecond threshold — the
exact thing `docs/ARCHITECTURE.md`'s m23-bu-1 entry says never to do. Under the recommendation the
residue is float epsilon.

### 3.2 Carry the elapsed cost forward as a beat offset added after the fact — LOSES

Breaks §2 in the worst way: clip schedule, automation origin and metronome plan were built from the
old value; only the anchor's `startBeats` moves. Result is a genuine **audio/playhead split** —
strictly worse than the current shared lag.

### 3.3 Reorder `startPlayers` so the expensive work precedes the beat commit — LOSES

Attractive: it would shrink the prediction horizon to near zero. **It does not work, for concrete
structural reasons.** `prepareAllPlayers(withFrameCount:)` preallocates for ALREADY-SCHEDULED buffers
(`PlaybackGraph.swift:3084-3093`, guarded by `node.hasPendingSchedule`), so it cannot precede
`scheduleAll`. `startablePlayerCount` (`:3072`) counts nodes with a raised enqueue ledger and is
meaningless before scheduling — and the existing `startLead` scaling depends on it. The
beat-independent work (`applyParameters`, `applyReferenceMonitorNodeState`) is ALREADY ahead of the
derivation point once change (a) is applied, so this alternative's entire remaining benefit is
already captured. Optimising `scheduleAll` itself is unbounded work with no completion criterion, and
any residual cost still needs accounting. Keep only as a later optimisation that would shrink the
budget.

### 3.5 Declare today's behaviour correct — "recovery is a PAUSE, so resume where you left off" — LOSES

The most tempting alternative, because it makes the defect disappear by definition. **It loses on the
recording interaction (§7) and on external sync.** The MIDI capture session and the recording
writer's accept window are host-clock-linear from a never-moving anchor and **do not pause**. Treating
recovery as a pause makes the playhead disagree, permanently, with where notes are actually stamped
for the rest of the take. Wall time is the shared reference; the transport must stay on it.

### 3.4 Pass a past anchor deliberately and let the SDK shift the origin — LOSES

Rejected on the m19-f probe already in-tree (`AudioEngine.swift:3002-3017`, `PlaybackGraph.swift:3069`):
a late `play(at:)` gives shifted-origin behaviour — the player's timeline zero becomes the actual
late start, so the whole roll runs late by (lateness + IO-quantum roundup), permanently, while the
playhead runs on time. **Split sync.** The clamp-forward rule exists so this is never reached.

---

## §4 Overrun: the consequence, named

**With clamp-forward, an overrun of δ produces exactly today's defect, of magnitude δ** — a SHARED
lag: audio and playhead still agree with each other, both δ behind wall time. Today's defect is the
same shape with δ ≈ 130 ms. So the fix's worst case is the current behaviour with a smaller constant,
and it is signalled.

**Without clamp-forward**, an overrun of δ produces a SPLIT: playhead on time, audio δ + IO-quantum
late for the entire roll. A different and worse failure class. **The design must never be
"simplified" by dropping the `max`.**

**The gap/offset trade, defended rather than discovered.** The dropout between `stopAllPlayers` and
the anchor is today `workA + workB + startLead`; under the fix it is `budget`, chosen ≥ that. So the
fix **lengthens the silent gap** by the safety margin in order to remove a **permanent** timing
offset. The gap is transient and bounded; the offset persists for the rest of the roll and corrupts
every subsequent beat→time mapping including the recording clock. The budget cap bounds the transient
by a constant the tree already tolerates for a normal start's lead.

---

## §5 Loop wrap

**A later derivation crossing a loop seam is CORRECT, not a hazard.** `beat(forElapsedSeconds:anchor:)`
(`:3163`) wraps modularly under an active `loopContext`; if the recovery work spans a wrap, the resume
beat lands just after `loopStartBeat`. Wall time kept moving, the loop kept cycling, and the
listener's position is inside the next cycle. The timeline law holds unchanged because the formula is
unchanged — only its argument moves.

**5.1 ⚠️ The derivation MUST happen in `recoverEngine` at the call site, NEVER inside `startPlayers`.**
`startPlayers` sets `loopContext = nil` at `:2972` and rebuilds it. A derivation after that line
silently takes the LINEAR branch and loses the wrap. **This is the single most likely way to implement
this item wrong,** and the §9.3 loop leg is the only automated check that catches it.

**5.2 Guard the `min(loop.endBeat, ...)` float edge.** `beat(forElapsedSeconds:)` clamps with
`min(loop.endBeat, ...)` at `:3167`. If float error returns exactly `loopEndBeat`, `startPlayers`'
guard `beats < loopEndBeat` (`:2976`) fails, `loopWindow` stays nil, and **recovery silently resumes
as a linear roll past the loop end — the loop turns itself off.** Measure-zero today and not worsened,
but the fix moves the derivation to a new instant and it costs one line: if a loop is active and the
derived beat is `>= loopEndBeat`, snap to `loopStartBeat`.

---

## §6 `lastKnownBeats` and the `catch` block

**Decision: `lastKnownBeats` (`:3304`) keeps the ENTRY value.** It means "the last beat that was
real" — taken two lines before `graph.stopAllPlayers()`, so it is the beat at which audio actually
stopped. The resume beat is a FUTURE beat under the fix; storing it there would make a failed
recovery report a beat that never sounded.

**The strong form of the argument** (not "recovery is atomic", which is the weak claim and would be
discarded by anyone who finds a non-atomic path): **`lastKnownBeats` has no reader inside the window
at all, by inspection.** The only parameter pass in the window is `graph.applyParameters(tracks:)` at
`:3317`, which passes no `playheadBeat` and takes the default `0` (`PlaybackGraph.swift:1498`); the
other in-window pass is inside `startAllPlayers`, which uses `stagedAutomationStart.fromBeat`
(`PlaybackGraph.swift:3205`). The conclusion does not rest on atomicity.

**The `catch` at `:3340` is unchanged and becomes correct for free.** It reports the entry
(stop-instant) value; because the resume derivation lives inside the `do` block after segment A, and
`engine.start()` throws from within segment A, the catch can never see the resume value. Add a
sentence saying this is deliberate, so a later author does not "helpfully" switch it.

### 6.2 `currentAnchor = nil` at `:3307` STAYS — a considered rejection, not an oversight

Keeping the old anchor live through recovery is appealing: the playhead would advance smoothly
through the dropout instead of plateauing. **Reject it.** It is *unobservable* — nothing can run
between `:3307` and `startPlayers`, because the routine is synchronous with no await points — and it
would make a FAILED recovery leave a live anchor with stopped players, so the next `startPlayback`
would early-out at `:773` ("already playing") on a dead transport. **Zero benefit, one real
regression.** (The smooth-playhead goal is real but belongs to m23-bs-4, which reaches it a different
way — by evaluating the pre-anchor region against the outgoing line.)

### 6.1 Cleared finding — do NOT re-investigate

`AudioEngine.swift:3317` calls `graph.applyParameters(tracks: lastTracks)` with no `playheadBeat`,
taking the default `0`. **This looks like a bug and is not.** `applyParameters` only uses
`playheadBeat` in its stopped-preview branch (`PlaybackGraph.swift:1502`, used at `:1538`), and
`startAllPlayers` re-applies parameters at the correct beat milliseconds later (`:3184-3205`). The
beat-0 preview lasts only for segment B, during which the players are stopped and the graph is
silent. Cosmetic and self-correcting. **No change.** Recorded because the next reader of
`recoverEngine` will find it and spend the same time.

---

## §7 Recording — confirmed, and the roadmap's warning points the OTHER way

The roadmap warned that "the recording writer's accept window is anchored to a never-moving M14
anchor". **Verified by reading the code: the fix IMPROVES recording correctness.**

- `writer.setAcceptWindow(reference: anchor.anchorHostTime, ...)` (`:2702` / `:2704`) is frozen at
  record start in absolute host time and never re-read or re-set. `recoverEngine` does not touch it.
- `MIDICaptureSession(anchorHostTime:anchorBeats:tempoMap:)` (`:2717`) is likewise frozen at record
  start; notes are stamped host-linearly from that anchor.
- Capture runs on `InputCapture`'s own engine with its own `handleConfigurationChange`
  (`InputCapture.swift:160`); `recoverEngine` is the OUTPUT engine's path.

So the capture clock does not move during recovery. **Today** a mid-take recovery leaves the playhead
~120 ms behind the clock notes are stamped against; **after the fix** they agree.

**⚠️ INDEPENDENTLY RE-VERIFIED BY THE ORCHESTRATOR 2026-08-02 by enumeration, because this claim
INVERTS the roadmap's stated risk and bs-2 proceeds only if it holds.** Every production write of the
capture clock, exhaustively: `writer.setAcceptWindow` has exactly **two** production call sites,
`AudioEngine.swift:2771` and `:2773`, both inside `startTakeBody`, both from `anchor.anchorHostTime`
at record start. `RecordingWriter.swift:159` is an internal wrapper (`setTargetHostTime`) whose only
callers in the entire tree are in `RecordingWriterTests.swift` — **no production caller**.
`midi.captureSession` is constructed once (`:2786`) and otherwise only set to nil (`:2836`, `:2879`,
`MIDIInputManager.swift:310`). **None of these sites is on the recovery path.** The roadmap's warning
that "the recording writer's accept window is anchored to a never-moving M14 anchor" is true and is
exactly why the fix HELPS: the window never moving is what makes today's post-recovery playhead
disagree with it.

**Bonus finding — the fix closes a second recording defect.** `stopRecording` clamps open notes with
`derivedLinearBeats()` (`:2799`), which reads the CURRENT (post-recovery) anchor. Today, after a
mid-take recovery, that returns a beat ~120 ms early, so a note that began after that point clamps to
a `stopBeat` earlier than its own start and collapses to the 0.001-beat floor (`:2797`). The fix
removes that.

**Caveat 1 (sign flip, bounded, acceptable).** Under `.atHostTime` the anchor is in the future and
`derivedLinearBeats()`'s `max(anchor.startBeats, ...)` clamp returns that future beat during the gap.
A `stopRecording` inside the gap clamps open notes slightly LONG (≤ budget) where today it clamps
them slightly SHORT (≤ 130 ms). Same magnitude, opposite sign — and long is the benign direction:
over-length is editable, collapse-to-floor is data loss.

**Caveat 2 (pre-existing, not worsened).** A recovery during a count-in already loses the count-in:
recovery passes no `countInBars`, so the clicks do not resume while the writer's window still
references the original count-in-delayed anchor. Observation, not scoped here.

**Precondition the implementation must enforce:** `.atHostTime` requires `countInBars == 0`, because
`anchorHost = clickAnchorHost + countInHostTicks` (`:3059`) would push the anchor past the target.
Every continuation site passes 0 today. Enforce with a `precondition`/comment and a site-pin assertion.

---

## §8 Implementation plan

**Step 1 (roadmap m23-bs-1) — instrument and measure, no behaviour change.** Three seams on the
`recoveryRestartCountForTesting` (`:2520`) / `outputPinReapplyCountForTesting` (`:2533`) convention —
`internal`, `private(set)`, production never branches on them:
`recoverySegmentACostSecondsForTesting`, `startPlayersScheduleCostSecondsForTesting` (entry → anchor
site, EXCLUDING the lead), `lastStartLeadSecondsForTesting` (post-cap). **A GATE, not a formality:**
the A/B split decides whether the budget is a constant or must be adaptive, and it is the only way to
know how much of the 72 ms recover-only figure is segment B. **Measure on a realistic project (~30
clips / 8 tracks), not only the one-clip fixture** — segment B's SCALING is what condemns the filed
shape and a one-clip measurement is structurally blind to it. Measure filtered AND full-suite.

**The decision rule, so the outcome is mechanical rather than a judgement call:**
- **Segment B < 5 ms with < 2 ms spread** → the prediction machinery is not worth its complexity;
  ship the simpler §3.1 shape plus a fixed 10 ms budget. (Judged unlikely for real projects, possible
  for the one-clip fixture — which is exactly why the multi-track leg is mandatory.)
- **Otherwise** → the recommended design; a CONSTANT budget if B's spread is < 25 % of its mean, and
  the last-measured × safety-factor feedback path if not.
- ⚠️ **The falsifier (§9.1): full-suite segment B must land tens-of-ms, not seconds.** If it is
  seconds-scale, a synchronous main-actor block is subject to the seconds-scale channel after all,
  the property witness's regime-invariance argument fails, and the verification design must be
  reconsidered before any implementation. **A falsifying result here is more valuable than a
  confirming one and must be reported prominently, not as a footnote.**

Regardless of the outcome, the clamp/counter/stderr shape and the §9.1 witness stay — neither depends
on the number.

**Step 2 (m23-bs-2) — the mechanism.** `StartAnchorPolicy` nested in `AudioEngine` near
`PlaybackAnchor` (`:157`), **no default** (the m23-bp/m23-bq reason: silence is how recovery
inherited the wrong answer). `startPlayers` gains a required `anchorPolicy:`. At the anchor site both
branches compute the existing expression as `earliest`, then `.asSoonAsPractical` → `earliest`
(byte-identical to today); `.atHostTime(target)` → `target` if `target >= earliest`, else `earliest`
plus an overrun counter, a recorded overrun magnitude, and a stderr note in the idiom of the existing
lead-cap warning at `:3022`.

> **⚠️ Landmine for the trusted branch — implement now, live-proven at bs-3.** The trusted branch
> computes `anchorSample = renderTime.sampleTime + ((startLead + countIn.delaySeconds) * hardwareRate).rounded()`
> (`:3036`). Under `.atHostTime` that is WRONG — the sample offset must derive from the ACTUAL host
> delta `target - renderTime.hostTime`, not from `startLead`, or `elapsedSeconds` (which prefers the
> sample path when `hasSampleAnchor`) reads a different clock from the host anchor. Recovery uses the
> untrusted branch, so this is source-pinned rather than live-exercised by bs-2.

**Step 3 — the budget** (numbers set by Step 1), one private helper:

```
horizon = clamp(lastScheduleCost * safetyFactor + lastStartLead,
                min: Self.startLeadSeconds,      // 0.06 — never shorter than a normal lead
                max: Self.maxStartLeadSeconds)   // 0.50 — the gap can never exceed an existing bound
```

Both bounds are EXISTING constants (`:415`, `:419`), so the fix introduces no new tolerance for gap
length. **Seed precondition, checked:** every continuation site is preceded by at least one start on
the same `AudioEngine` instance — `recoverEngine` early-returns unless `currentAnchor != nil`
(`:3294`); the rewire and rebuild resumes both capture from a live anchor (`:930`, `:990`); and
`watchdogRestart`'s `if !isRunning { try prepare() }` fallthrough (`:3397`) is a cold start, not a
continuation. So a measured sample always exists and the seed is not load-bearing. **If Step 1 shows
B is small and tight, replace the adaptive term with a constant and delete the feedback path.**

**Step 4 — wire `recoverEngine`:**

```swift
let now = mach_absolute_time()
let beats = resumeBeat(at: now, anchor: anchor)   // the STOP-instant beat
lastKnownBeats = beats                            // :3304 UNCHANGED (§6)
graph.stopAllPlayers()
currentAnchor = nil
do {
    // ... segment A unchanged ...
    // m23-bs: derive for the instant the anchor will ACTUALLY land.
    // MUST be here, not inside startPlayers: startPlayers clears
    // loopContext at :2972 and the modular wrap would be lost (§5.1).
    let anchorHost = mach_absolute_time() + continuationHorizonTicks()
    let resume = resumeBeat(at: anchorHost, anchor: anchor)
    startPlayers(fromBeat: resume, tempoMap: anchor.tempoMap, cause: .continuation,
                 renderClockTrusted: false, anchorPolicy: .atHostTime(anchorHost))
} catch { /* unchanged — reports `beats`, the stop-instant value (§6.3) */ }
```

`resumeBeat(at:anchor:)` is `:3296-3303` generalised from `now` to an arbitrary host time — one home,
one caller today, and the place every bs-3 site must come to.

**Step 5 — ⚠️ the call-site formatting collision (verified by the orchestrator, read before typing).**
`NoteChaseSiteTests.internalForwardsAreTransparent` (`Tests/DAWEngineTests/NoteChaseSiteTests.swift:143-146`)
filters source lines containing `cause: cause` and asserts one of them ALSO contains `startPlayers(`
— **a per-line match**. The `restart` forward at `AudioEngine.swift:2919` is already 98 characters;
adding a parameter wraps it and reds that test. (`RenderClockTrustSiteTests` is NOT affected — its
`callText(from:)` joins across lines until the parens balance.) The formatting that satisfies both:

```swift
        startPlayers(fromBeat: beats, tempoMap: tempoMap, cause: cause,
                     renderClockTrusted: true, anchorPolicy: .asSoonAsPractical)
```

Also keep `renderClockTrusted: Bool` on its own declaration line (`:2967`) — `parameterHasNoDefault`
requires exactly one line containing it with no `Bool =`.

**Step 6 — the new site pin.** `Tests/DAWEngineTests/StartAnchorPolicySiteTests.swift`, mirroring
`RenderClockTrustSiteTests` in structure.

⚠️ **LINE NUMBERS — RE-VERIFIED BY THE ORCHESTRATOR AFTER m23-bs-1 LANDED (2026-08-02).** The design
passes were written against the pre-bs-1 tree and the instrumentation seams shifted everything below
`:2572`. The **six real call sites** are now `:799` (`startPlayback`), `:944` (rewire resume),
`:1124` (rebuild resume), **`:2740`** (`startTakeBody`, was 2671), **`:2988`** (`restart`, was 2919),
**`:3422`** (`recoverEngine`, was 3338). Re-grep before editing rather than trusting any of these —
bs-2's own edits will shift them again.

⚠️ **AND THE `restart` LINE HAS ALREADY BEEN REFORMATTED SINCE THE DESIGN WAS WRITTEN.** It now reads
`startPlayers(fromBeat: beats, tempoMap: tempoMap, renderClockTrusted: true, cause: cause)` — one
line, ~96 chars, with `cause: cause` LAST rather than where the design assumed. `AudioEngine.swift:2985`
already carries an in-source comment pinning the same-line constraint. Adding the policy argument
(~34 chars) forces a wrap regardless, so the Step 5 reordering still applies exactly as written.

⚠️ **NAME THE PARAMETER ONCE.** Design pass 3 called it `anchor:`; passes 1–2 and this record call it
**`anchorPolicy:`**. Use `anchorPolicy:` throughout — enum declaration, all six call sites, and the
site pin's match string — or the pin will silently match nothing.

Expected sequence in file order:

| # | site | policy | why |
|---|---|---|---|
| 1 | `startPlayback` | `.asSoonAsPractical` | user chose the beat |
| 2 | `tracksDidChangeBody` (rewire resume) | `.asSoonAsPractical` | **bs-3 flips this** |
| 3 | `rebuildEngine` resume | `.asSoonAsPractical` | **bs-3 flips this — the largest instance** |
| 4 | `startTakeBody` | `.asSoonAsPractical` | record start, user chose the beat |
| 5 | `restart` | `.asSoonAsPractical` | **bs-3 makes this a forwarded parameter** |
| 6 | `recoverEngine` | `.atHostTime` | **m23-bs** |

The table doubles as bs-3's scope statement: three answers change, and the compiler plus this pin
enumerate them.

---

## §9 Verification design

### 9.1 The property witness — adopted, RELOCATED

A property witness exists and is the strongest available answer: both anchors are immutable value
types, the discontinuity is fixed the instant `startPlayers` returns and does not decay, and there is
no poll interval, so m23-bu-1's clause (3) about witness margin does not apply.

**⚠️ But the arithmetic must NOT live in the engine.** Export raw scalars only —
`anchorLineForTesting: (startBeats: Double, anchorHostTime: UInt64)?`.

**A precomputed in-engine difference must not exist as a seam at all** — not merely "the test-side
version is preferred". Under the fix it recomputes the same expression the fix computed and subtracts
it from itself: **identically 0.000 by algebra, even against a broken `TempoMap`.** It *does* redden
on the mutant, and that is precisely the trap — a seam that reddens on the mutant is one a future
author will keep and assert on, while it cannot catch the class of bug where the derivation itself is
wrong (wrong map, wrong loop branch, wrong sign). Say so in the seam's own doc comment.

**Protocol** (`Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift`, device-gated,
`.serialized` **for device contention only — never cite it as a starvation fix**):

1. Constant 120 BPM map, loop OFF, one track, start playback at beat 0.
2. Roll ~500 ms (well past the 60 ms lead-in; no poll interval, so no margin parameter needed).
3. Read `(b0, h0) = anchorLineForTesting`.
4. `try engine.watchdogRestart()`.
5. Read `(b1, h1)`, `recoveryRestartCountForTesting` (must be 0→1 — the m23-bt discriminator; a green
   read-back against a recovery that early-returned proves nothing), and the overrun counter.
6. If overrun > 0 → **skip and report**. A starved window is a machine fact; make the skip VISIBLE or
   it becomes a silent coverage hole.
7. Assert, with the test's own closed form and no engine helper:
   `abs(b1 - (b0 + 2.0 * AVAudioTime.seconds(forHostTime: h1 - h0))) <= epsilon`

**On the load-dependence objection (raised by the orchestrator, RESOLVED):** on the healthy path
`anchorHostTime` is an INTEGER COPY of the `H` the resume beat was derived for, so the residue is the
float error of one host-tick→seconds→beat round trip. It does not scale with the work, the project or
the machine. Load determines only WHICH PATH is taken, and the overrun counter reports that in-band.
**So the ceiling is a float tolerance, not a guessed millisecond threshold** — the m23-bu-1 rule
satisfied by removing the exposure rather than surviving it.

**⚠️ THE ARGUMENT THAT ACTUALLY SETTLES THIS — the two witnesses sit on OPPOSITE SIDES of the
m23-bu-1 finding.** This is the reusable insight of the whole item and it is not obvious. m23-bu-1
added a third channel specifically to establish that the seconds-scale delays under full-suite load
are **Swift-runtime scheduling latency, not OS-level CPU starvation**: a plain `DispatchSourceTimer`
on its own queue stayed at 18–98 ms across three full-suite runs while main-actor gaps hit
1803 / 3783 / 4218 ms. The machine has thread slack; what is queued is getting scheduled. Now place
the two witnesses against that:

| Witness | Depends on | Full-suite exposure |
|---|---|---|
| `RecoveryPlayheadTests` lag metric | the playhead `Task` being **scheduled** at 30 Hz | the seconds-scale channel — 3 pushes where 36 are nominal |
| Anchor-continuity property | the synchronous straight-line **execution** of `recoverEngine` | the queue-jitter channel — tens of ms |

`recoverEngine` → `startPlayers` → `startAllPlayers` is one uninterrupted synchronous block with no
await points; once executing on the main actor it is not preempted by other Swift tasks, only by the
OS — which m23-bu-1 measured at 18–98 ms. **So budgeting ~100 ms of OS-preemption slack makes the
overrun path rare even under full-suite load, and the property witness is trustworthy in exactly the
regime where the timing leg is not.** ⚠️ **This claim is FALSIFIABLE and m23-bs-1 tests it:** if
full-suite segment B comes back seconds-scale rather than tens-of-ms, a synchronous main-actor block
is subject to the seconds-scale channel after all, this argument fails, and the verification design
must be re-examined before implementation. Take that measurement early.

**A second immunity, and it is the precise failure that killed the m23-bq metric:** the property
witness is **roll-duration-independent**. A `Task.sleep(for: .milliseconds(2000))` that resumes 17 s
late (measured, ROADMAP:548) changes nothing — the identity holds between two anchors however long
the roll was.

**Epsilon discipline (required).** Do not guess. Start at `1e-3` as an explicitly-labelled
not-yet-tightened placeholder with a `// TIGHTEN ME` carrying the printed value, **print the measured
value on every run**, and **tighten to measured-worst × 10 at close-out**. Expect ~1e-6; **anything
above 1e-4 means a real precision problem worth understanding before closing**, not a tolerance to
widen. A guessed-loose epsilon on the one
assertion carrying the regression guard is the same failure as a guessed timing ceiling, one layer
in. Record the final value and its justification in the file header.

**⚠️ THE SKIP IS ITSELF A COVERAGE HOLE UNLESS BOUNDED — three assertions, only the first skippable.**
Step 6 above skips when the overrun counter is non-zero. A degenerate implementation (budget ≡ 0)
would overrun *every* time and skip *every* time, passing forever while testing nothing. Close it:

1. **Guard (skippable).** `overrunCount == 0` → `|b1 − (b0 + 2·Δt)| <= ε`. The regression guard.
2. **Consistency (NEVER skipped).** `|b1 − (b0 + 2·Δt)| <= reportedOverrunBeats + ε`, unconditionally.
   It relates two INDEPENDENTLY EXPORTED quantities, so it catches a wrong derivation regardless of
   load or which path was taken.
3. **Anti-degenerate (NEVER skipped).** `lastContinuationBudgetSecondsForTesting > 0` and within
   `[floor, cap]` — a pure read-back starvation cannot touch, which a budget-≡-0 implementation
   cannot pass.

The skip must be LOUD — `print("[measured] m23-bs SKIPPED — budget overrun ×N, worst X ms")`, the
`NO OUTPUT DEVICE` idiom already at `RecoveryPlayheadTests.swift:204`. A silent skip is exactly the
hole m23-bu-2 exists to prevent.

**Anti-vacuity mutants (mandatory), THREE of them.** (a) Revert `recoverEngine` to entry-derivation →
the guard must redden; expected ≈0.26 beats against ~1e-3, a ~260× margin; run filtered and record
the number in the header. (b) Set the budget to 0 → assertion 3 must redden. (c) Make the clamp
unconditional (`anchorHost = H`, no `max`) → the gate must **NOT** redden, proving it does not
accidentally claim to cover the past-anchor case, which is prevented by construction rather than by
test.

**The budget gets its own pure home:** `Sources/DAWEngine/ContinuationAnchorBudget.swift` — an `enum`
namespace, one static function, no state, headless-testable, on the `ArrangeDropSnap` one-home model,
with `ContinuationAnchorBudgetTests` pinning floor, cap and monotonicity. Keeping it out of
`AudioEngine` is what stops a second budget computation appearing at the bs-3 sites.

### 9.2 Which leg carries the regression guard

**The property assertion carries it. `RecoveryPlayheadTests` becomes corroboration.**

- The property seam proves the two anchor lines coincide. It must **never** be loosened. If it fails,
  the engine is wrong.
- The timing leg proves the coinciding lines correspond to something audible. It **may** be loosened
  freely. If it flakes under full-suite load, loosen the TIMING leg, never the property assertion.

**Put that sentence in both file headers, in those words.** It is the thing most likely to be
inverted by a future author under flake pressure.

### 9.3 The loop-wrap leg — do not drop it

Second property leg, short loop (~2 beats), recovery timed to land near the seam; the test computes
the modular expectation itself (`within = (s - head) mod cycle; expected = loopStart + 2.0 * within`).
Looser epsilon acceptable (the modular branch has an extra subtraction and a `min` clamp) — but state
its derivation, do not pick it. **This is the ONLY automated check that catches the §5.1 mistake:** an
implementation that derived inside `startPlayers` after `loopContext = nil` takes the linear branch
and reds here while the loop-off leg stays green.

### 9.4 `plateauMs` — do NOT assert on it, in either direction

The plateau and the lag are distinct quantities that this fix moves in OPPOSITE directions.
`maxLagBeats` measures the beat OFFSET of the republished line — the fix drives it to zero.
`plateauMs` measures the GAP — the fix leaves it and probably **grows** it (gap = budget ≥ today's
`work + lead`, §4). **So asserting a small plateau would red a correct fix.** The header at
`RecoveryPlayheadTests.swift:93-96` already says "NEVER asserted on"; extend it with this reason,
because "the fix makes this number bigger on purpose" is much stronger protection than "we chose not
to assert on it".

Independently, the orchestrator measured `plateauMs` at 43 / 0 / 41 / 39 across four runs whose lag
was identical (0.268) — so the plateau is a sampling artifact of where the 30 Hz pushes land, **not
an independent witness**, and must not be counted as a second proof. **The mechanism, diagnosed:**
`plateauMs` counts consecutive post-mark pushes within 0.02 beats of the first, on a 33 ms grid,
while measuring a ~60 ms quantity — so its achievable values are `{0, 33, 66, …}` and 43/41/39 are
one-push plateaus with the grid offset varying. **The variance is ALIASING, not physics.**

**But the gap itself does deserve a bound — just not through this metric.** It is available as a
PROPERTY from the same seam: `anchorHostTime` minus the instant `stopAllPlayers()` returned is the
exact silent gap in host ticks. Assert that against `maxContinuationBudgetSeconds` plus slack. No
polling, no sampling — and it turns the one reviewer-objectionable consequence of this design (§4's
transient-gap-for-permanent-offset trade) into a machine-checked invariant rather than a promise. So
**both quantities the fix touches become property assertions, and the timing leg becomes purely
corroborative.**

**Second sign-flip warning for the same header.** Under `.atHostTime` the playhead sits at a FUTURE
beat during the gap, so it reads AHEAD of wall time by up to the budget, then wall time catches up.
The current metric tracks only positive lag (`lag = expected - beat`) so this is invisible — **a
future author who "improves" the metric to `abs(...)` would red a correct fix.** Say so.

### 9.5 The delta metric — agreed, and it gets a clean prediction

A delta (restart worst-lag minus control worst-lag, both in the same run) is self-calibrating against
ambient noise and strictly better than the absolute ceiling.

**The post-fix expected value is ZERO, and that is derivable rather than guessed.** The control's
0.124 beats is the INITIAL `startPlayback` lead — beat 0 sounds at `t0 + lead`, so the whole roll is
permanently ~60 ms behind wall-time-from-`t0`. The fix preserves the outgoing anchor's line exactly,
INCLUDING that offset. So post-fix the restart leg should converge to the control leg.
Pre-fix delta: **0.259** (watchdog), **0.145** (recover-only). Post-fix: **≈ 0 + overrun.**

**Caveat, stated honestly:** the delta cancels ambient inflation only if both legs are starved
comparably. They are measured sequentially in one test, so roughly — but a burst hitting only the
restart leg inflates the delta and can flake. Acceptable precisely because this leg is corroboration
(§9.2), and its documented remedy is loosening.

### 9.6 The 1.2-beat ceiling — SETTLED at 0.25, after the claim flipped TWICE

**⚠️ READ THIS SUBSECTION'S HISTORY BEFORE CHANGING IT. Two successive design passes gave two
different wrong answers here, and the second wrong answer is the one a careful reader is most likely
to re-derive.** Settled by the orchestrator reading the source, not by picking a pass.

**THE SETTLED ANSWER: `maxLagBeats` drops 1.2 → 0.25, and the tightening is safe under starvation.**

*Derivation, not a guess.* Post-fix the recovery re-aligns the transport to the ORIGINAL anchor's
line, which already carries the initial start's 0.06 s lead. So the restart leg's steady-state lag
becomes the CONTROL's lag — the permanent `startLead` offset relative to the fixture's `t0`. **The
falsifiable prediction is that all three legs converge on ≈0.12** (the control's measured
0.119–0.125). 0.25 is 2× that, ~6× the filtered run-to-run spread above it, and **mutant-red by
construction on the unfixed tree**: today's recover-only reads 0.268 and restart 0.362–0.383, both
above 0.25, while the control passes with 2× margin. If the implementer measures anything other than
convergence-on-control, the fix is not doing what this design says.

Additionally: **add the in-run delta leg** `restart.maxLagBeats − control.maxLagBeats <= 0.10` (today
0.259, post-fix ≈0.00) — the sharper instrument, and it cancels the systematic lead offset. Keep it
as a SECOND assertion, not a replacement. Add the overrun skip-and-report guard to both legs.
**Keep the `rollMs >= 3 × maxLagBeats-as-time` law in the header but RECOMPUTE it:** at 0.25 beats
the floor is 375 ms, so the existing 2000 ms is comfortably inside. Do not delete the law — its
purpose (a future author shortening `rollMs` disarms the m23-bq freeze guard) still applies.

#### The two withdrawn claims, named rather than deleted

**Withdrawn claim 1 (design pass 1): "the ceiling drops to 0.4 as 3× the predicted post-fix worst."**
Wrong because the 3× multiplier was inherited from the reasoning that produced 1.2 (3× the
then-measured 0.37) without re-examining whether the multiplier was ever load-justified. Superseded.

**Withdrawn claim 2 (design pass 2): "1.2 is not starvation-safe in the first place — a push delayed
1.8 s reports ~3.6 beats of apparent lag, so the leg survives by SAMPLING LUCK and no ceiling below
~9 beats is safe."** This is the dangerous one: it is a natural inference from m23-bu-1's measured
1803–4218 ms main-actor gaps, it sounds rigorous, and **it is false.**

**⚠️ WHY IT IS FALSE — VERIFIED BY THE ORCHESTRATOR FROM THE SOURCE, because two passes disagreed.**
Inside `startPlayheadTask` the ONLY `await` is the `try? await Task.sleep(for: .milliseconds(33))`
at the top of the loop. Between `var beats = self.derivedBeats()` and `self.playheadHandler?(beats)`
there is **no suspension point** — only `serviceLoop` and `metronome.topUp`, both synchronous.
(Verified with `sed -n '/private func startPlayheadTask/,/^    }/p' | grep 'await\|derivedBeats\|playheadHandler'`:
one `await`, and it precedes the derivation.) The fixture's sample is
`(Date().timeIntervalSince(t0) * 1000, beat)` taken inside that handler, so **the beat and its
timestamp are read in the same synchronous main-actor run.** A starved tick fires LATE, but
`derivedBeats()` reads the host clock at that same late moment — so the sample is late but
INTERNALLY CONSISTENT.

> **THE LAW: starvation costs this metric sample COUNT, never sample ACCURACY.** That is exactly why
> m23-bq's lag-against-wall-clock metric works where advance-per-window did not, and it is why
> tightening the ceiling cannot create a false RED under load.

**The consequence for the fork:** option (b) — gating a tight ceiling on a contention detector — is
**rejected, not deferred**. Its premise was that a tight ceiling is unsafe under starvation; that
premise is false, so no `pushesAfterMark` gate and **no dependency on the m23-bu-2 helper is
created**. (An overrun skip guard is still wanted, but it keys off the engine's own overrun counter —
purpose-built, exact, and in-band — which is a strictly better detector than any generic one.)

#### Superseded text from design pass 2, retained for the reasoning only

Withdrawn claim 2's full reasoning was: m23-bu-1 measured main-actor gaps of 1.8–4.2 s, a push
delayed 1.8 s would report ~3.6 beats of apparent lag, both figures blow through 1.2, the leg yields
only ~3 post-mark pushes under starvation so the odds of one landing in a multi-second gap are low —
therefore it passes by luck and no ceiling below ~9 beats is safe. It prescribed keeping 1.2 as an
always-armed backstop, adding a *self-disarming* 0.25 ceiling gated on `pushesAfterMark >= nominal/2`,
a delta of 0.15, and a `DEGRADED` print.

**Every step of that is sound EXCEPT the first, and the first is false** — the delayed push does not
report inflated lag, because its beat and its timestamp are read together (above). With the premise
gone, the gating, the backstop-plus-tight-ceiling split, and the `DEGRADED` machinery are all
unnecessary complexity answering a problem that does not exist. **Do not reintroduce them.** The one
piece worth keeping from that pass is the instinct that a leg quietly asserting less than it appears
to is a coverage hole — which is real, and is served here by the overrun skip-and-report guard.

**⚠️ Consequential edit the implementer must not miss.** The header at `RecoveryPlayheadTests.swift:39-43`
states an invariant: `rollMs` must be ≥ 3× `maxLagBeats` expressed as time, because the m23-bq
defect's freeze equals `rollMs` of music. **At the SETTLED 0.25-beat ceiling the floor is
`3 × 0.25 × 500 ms = 375 ms`, and the unchanged 2000 ms keeps 5.3× margin.** **Re-derive and rewrite
that paragraph rather than leaving it stating obsolete arithmetic** — a stale invariant next to a
changed number is how the next author disarms the m23-bq guard while believing they are following the
header.

> ⚠️ **CORRECTED AT THE m23-bs-2 IMPLEMENTATION (2026-08-02).** This paragraph itself previously read
> "dropping the ceiling to 0.4 beats (200 ms) drops the requirement to `rollMs >= 600 ms`; the current
> 2000 ms keeps 3.3× margin" — arithmetic computed for the **withdrawn** 0.4-beat ceiling of design
> pass 1, sitting directly beneath the subsection that settles the ceiling at 0.25. §13.11 Step 8
> flagged it against itself; it is fixed above. The instance is worth keeping in mind rather than
> forgetting: a stale margin beside a changed number survived two design passes *in the very
> paragraph warning about stale margins beside changed numbers.*

### 9.7 Regression surface to re-run

`RenderClockTrustSiteTests`, `NoteChaseSiteTests` (the §5/Step 5 formatting collision is the EXPECTED
first failure if Step 5 is skipped), `RecoveryOutputPinGateTests`, `RecoveryPlayheadTests`,
`EngineWatchdogTests`, plus a full `./scripts/test.sh` backgrounded (~90 s) with `grep '^✘'` —
**`./scripts/test.sh` exits 0 on a failed run.**

---

## §10 Follow-ups, ranked by evidence

- **m23-bs-3 (this document's "bs-2") — the other three continuation sites.** `rebuildEngine` resume
  (`:944`, `:1124`) is the **largest** instance — captures `derivedBeats()` at quiesce then performs a
  full cold rebuild, unbounded by anything bs-1 measures, and it is the m20-e device-flip path.
  `restart` (`:928`, via `tracksDidChangeBody`) is the **most frequent** — every piano-roll note edit
  and clip move while rolling. `setTempo` (`:851`) third.
- **m23-bs-4 (this document's "bs-3") — playhead continuity through the gap.** Under the fix the new
  anchor's line IS the old line, so an anchor able to evaluate the pre-anchor region against the
  outgoing line would make the playhead perfectly continuous — no plateau, no forward jump. Deferred:
  it adds a second reader to the anchor law, which the ONE-home registry constrains.
- **Observation (no item):** a recovery during a count-in loses the count-in (§7 caveat 2).
- **Cleared, do not re-investigate:** `applyParameters(playheadBeat: 0)` at `:3317` (§6.1).

---

## §11 Risk register

| Risk | Mitigation |
|---|---|
| Derivation placed inside `startPlayers` → loop wrap silently lost | §5.1 + the §9.3 loop leg is the only automated catch |
| `NoteChaseSiteTests` reds on the `restart` call reformat | §8 Step 5 gives the exact formatting (verified) |
| In-engine difference seam added "for convenience" and asserted on | §9.1 forbids it in the seam's own doc comment |
| Epsilon left at the guessed placeholder | §9.1 makes tightening a required close-out step |
| Future author asserts on `plateauMs`, or makes the lag metric two-sided | §9.4 header text explains why both red a correct fix |
| `rollMs` invariant left stating obsolete arithmetic after the ceiling drops | §9.6 requires re-deriving that paragraph |
| Budget chosen before measurement | bs-1 is a gate; only the SHAPE is pinned in advance |
| Trusted-branch `anchorSample` not updated for `.atHostTime` | §8 Step 2 landmine; source-pinned at bs-2, live-proven at bs-3 |

---

## §12 `docs/ARCHITECTURE.md` entry to add at the bs-2 close-out

> **The schedule origin and the anchor instant are one identity, and continuation starts choose the
> instant first (m23-bs, SETTLED \<date\>).** `startBeats` is the beat that occurs at `anchorHostTime`
> — for the clip schedule, the automation origin (`PlaybackGraph.stagedAutomationStart`), the
> metronome, the reference track and the playhead simultaneously. A start that derives its beat at one
> instant and anchors at another republishes a line the music is not on, and the error is permanent for
> the rest of the roll. `AudioEngine.StartAnchorPolicy` is THE ONE HOME of that choice, with no default
> for the m23-bp/m23-bq reason: `.asSoonAsPractical` means the caller chose the beat (relocation);
> `.atHostTime` means the beat was derived FOR that instant off the outgoing anchor's line
> (continuation). Overrun clamps the anchor FORWARD, never backward — a past anchor gives m19-f
> shifted-origin behaviour, i.e. audio late and playhead on time, which is a sync split and strictly
> worse than a shared lag. **The verification consequence is the reason this shape was chosen over the
> simpler "re-derive later":** the healthy-path residue is an integer copy and therefore float epsilon,
> load-independent, so the continuity assertion is a float tolerance rather than a guessed millisecond
> threshold — the m23-bu-1 rule satisfied by REMOVING the exposure rather than surviving it. The
> witness is the raw anchor pair (`anchorLineForTesting`) with the arithmetic done TEST-SIDE; an
> in-engine precomputed difference is FORBIDDEN because under this fix it is identically zero by
> algebra and would read green against a broken `TempoMap`.

Add `AudioEngine.StartAnchorPolicy` to the "ONE home" registry in memory at the bs-2 close-out.

---

## §13 — BUDGET REDESIGN (m23-bs-2, post-bs-1 measurement)

**Status:** budget settled 2026-08-02 (`daw-architect`, fresh pass on the bs-1 measurement).
**This section REPLACES §8 Step 3 in its entirety.** §1–§7 and §9–§12 stand except where §13.9 names
a correction. Nothing here needs full Xcode: no entitlements, no AUv3, no signing — plain
`swift build` / `./scripts/test.sh` work.

**What changed and why there is a new section rather than an edit.** §8 Step 3 sized the budget on
segment B. bs-1 measured B at ~1 % of the defect, flat and non-scaling, with a spread that is OS
preemption of a synchronous block. The dominant term is the anchor LEAD (~75 %), and the lead is
computed inside `startPlayers` downstream of the beat commit — a genuine cycle. §13 sizes the budget
on the lead, forecasts the lead from a quantity that is available BEFORE the cycle closes, and
proves that the forecast errs in the cheap direction.

### 13.1 The ~14 ms residual is the render-clock lead, and it is NOT a budget term

**This is the first decision, because it removes a term the roadmap brief assumed was in the budget.**

bs-1 left two hypotheses for the residual — (a) a clock-basis offset, (b) the output buffer — and
called them competing with opposite consequences. **They are the same mechanism.** Write δ for the
amount by which `outputNode.lastRenderTime.hostTime` leads `mach_absolute_time()` at the instant it
is read. δ is a device property (a render callback is handed a presentation-domain timestamp; the
callback executes about one buffer + the presentation latency before that instant), so hypothesis (b)
is simply the MAGNITUDE of hypothesis (a). Now the algebra, at 120 BPM with β = 2 beats/s:

- Outgoing start took the TRUSTED branch (`startPlayback` passes `renderClockTrusted: true`), so
  `anchorHost0 = h0 + lead0` where `h0 = lastRenderTime.hostTime ≈ W0 + δ`.
- The pre-recovery playhead reads the SAMPLE branch (`elapsedSeconds`, `hasSampleAnchor` true), which
  yields `pushedBefore(W) = b0 + β·(W − W0 − lead0)`.
- Recovery derives `b1` off the host clock and (m23-bq) anchors host-only, so
  `pushedAfter(W) = b1 + β·(W − anchorHost1)`.
- Substituting today's entry-time derivation `b1 = b0 + β·(W_entry − W0 − δ − lead0)` gives

  `pushedBefore(W) − pushedAfter(W) = β·(A + B + lead1 + δ)`.

**So the measured backward step is `A + B + lead + δ`, and δ is exactly bs-1's residual — invariant
to project size and to whether the engine bounced, because it is a property of the device, not of
the work.** That reproduces the measurement rather than assuming it, and it is why the residual sat
at the `bufferFrames/rate + presentationLatency` floor to three decimals.

**Now put δ under the FIX.** With `b1 = resumeBeat(at: anchorHost1, anchor: oldAnchor)` the A/B/lead
terms cancel by construction and

  `pushedBefore(W) − pushedAfter(W) = β·δ  ≈  0.028 beats on this machine.`

**δ must NOT be added to the resume beat.** Both `anchorHost0` and `anchorHost1` are presentation-
domain instants meaning the same thing — "the wall-clock moment beat `startBeats` is AUDIBLE".
Preserving the outgoing line is preserving what is actually coming out of the speaker. Adding δ to
`b1` would push the AUDIO forward by ~14 ms in order to make a DISPLAY reading continuous: an audio
discontinuity introduced to hide a display one. That is §3.2's failure class exactly, and §13 refuses
it for §3.2's reason.

**Semantics note (not a proof, and it should not be dressed as one).** The residue is a change of
display basis, and it moves toward the more defensible basis: the sample branch shows the beat being
RENDERED (audible δ later), the host branch shows the beat audible NOW. A user watching the playhead
after recovery sees the audible position. Whether the pre-recovery basis should also change is a
separate question and is NOT in scope — filed below.

**Where the "derive it, never hardcode it" requirement actually lands.** The roadmap brief is right
that δ must be derived rather than inherited as "13 ms"; §13 RELOCATES that requirement from the
budget to the **test's expected value**. Two derivations, and both are wanted because their agreement
is a falsifiable prediction rather than an assumption:

- **Direct (preferred, load-bearing):** `δ = AVAudioTime.seconds(forHostTime: renderTime.hostTime − mach_absolute_time())`
  on a RUNNING engine, `renderTime = outputNode.lastRenderTime` with `isHostTimeValid`. One
  subtraction, no CoreAudio property calls, correct at any buffer size and sample rate, and it
  measures the quantity the algebra above names instead of reconstructing it.
- **Cross-check (printed, never asserted):** `bufferFrames / sampleRate + outputNode.presentationLatency`,
  the pair bs-1's `deviceContext()` already prints (`Tests/DAWEngineTests/RecoveryCostSplitTests.swift:484-503`),
  with `bufferFrames` from `kAudioDevicePropertyBufferFrameSize`. ⚠️ **Read it off the ENGINE's
  current output device, not `HardwareDevices.defaultDeviceID(.output)`** — m20-j gave the app an
  app-local output-device pin, so the default device and the engine's device can differ, and bs-1's
  helper takes the default. Print both and their difference; a persistent disagreement means the
  mechanism above is wrong and §13.1 needs re-reading.

⚠️ **The direct read is only valid on a LIVE engine.** After `watchdogRestart`'s `engine.stop()` the
render clock reports the previous session (that is m23-bq's whole finding), so a read taken inside a
bounced recovery is meaningless. Because δ is a TEST-side quantity in this design, measure it with a
throwaway `AVAudioEngine` in the test (bs-1's `deviceContext()` precedent) rather than adding a
production seam whose validity depends on the branch taken.

**Observation, no item (the §10 idiom):** the playhead's display basis is not uniform across a
recovery — sample-clock ("being rendered") before, host-clock ("audible now") after — and the ~14 ms
step at the seam is that difference made visible. Unifying it is a product decision about what the
playhead means, not a defect, and it is NOT bs-2, bs-3 or bs-4.

### 13.2 THE BUDGET — the decision

`recoverEngine` predicts

```
H  =  mach_absolute_time()            // read AFTER segment A, immediately before the derivation
      + hostTime(forSeconds: horizon)

horizon(n)  =  StartAnchorBudget.lead(forStartablePlayerCount: n).seconds   // the SAME formula startPlayers uses
               + StartAnchorBudget.scheduleAllowanceSeconds                 // 0.030

n           =  graph.startablePlayerCount, READ AT RECOVERY ENTRY (before stopAllPlayers)
```

with `lead(n) = min(0.5, max(0.06, 0.02 + 0.008·n))` — today's expression at `AudioEngine.swift:3089`,
relocated to one home (§13.4), not re-typed.

**Where each term comes from at runtime.**

| term | source | when read | why there |
|---|---|---|---|
| `n` | `graph.startablePlayerCount` (`PlaybackGraph.swift:3072`) | recovery ENTRY, **before** `stopAllPlayers()` (`AudioEngine.swift:3388`) | `stopAllPlayers` calls `noteStopped()` and the ledger goes to zero — read it later and the forecast silently collapses to the floor |
| `lead(n)` | `StartAnchorBudget.lead` | at the derivation point | identical function to the one `startPlayers` will evaluate, so the two agree whenever `n` does |
| `0.030` | `StartAnchorBudget.scheduleAllowanceSeconds` | constant | covers segment B (bs-1 worst 20.2 ms) with 1.5× margin, and buys ~3 players of unforeseen-count headroom |
| `mach_absolute_time()` | host clock | after segment A | eliminates A exactly rather than estimating it (§1a); A is the least predictable term (0.9–48 ms, two overlapping mechanisms bs-1 could not separate) |

**The error bound, both directions — and the asymmetry is the whole argument.**

The clamp condition inside `startPlayers` is `H ≥ earliest = W_anchor + lead_actual` where `W_anchor`
is the `mach_absolute_time()` at the anchor site and `W_anchor − W_derive = B_actual`. So

  `overrun  ⟺  B_actual  >  0.030 + (lead_est − lead_actual)  =  0.030 + 0.008·Δn`,  Δn = n_entry − n_resume ≥ 0 (§13.3).

- **Over-prediction** (the normal case): magnitude `0.030 − B_actual + 0.008·Δn`; typically **~29 ms**,
  worst case `0.030 + (0.5 − 0.06) = 0.47 s` when a very large project resumes where almost nothing is
  left to play. **Cost: ZERO timing error.** The beat was derived FOR `H` and the anchor lands AT `H`;
  the line is continuous whatever `H` is. What it costs is (i) a longer silent gap and (ii) a longer
  playhead PLATEAU — during `[now, H]` the anchor is future-dated and `derivedBeats`' `max(startBeats, …)`
  clamp pins the playhead at the resume beat, so it reads AHEAD of wall time by up to the excursion
  and then wall time catches up. Both transient. (ii) is the reason NOT to simply use the 0.5 cap.
- **Under-prediction** (overrun): clamp forward, magnitude `B_actual − 0.030 − 0.008·Δn`. Zero in every
  one of bs-1's 32 samples (B max 20.2 ms). Its realistic worst is the OS-preemption tail m23-bu-1
  measured for a synchronous main-actor block, 18–98 ms, i.e. **≤ ~68 ms after the allowance** —
  against today's unconditional 79–215 ms. **Even the pathological case is better than today**, and it
  is counted and printed rather than silent.

**Gap arithmetic, stated so nobody has to re-derive it.** Today `gap = A_after_stop + B + lead`
(~0.06–0.11 s one clip, ~0.18–0.21 s realistic). Under the fix `gap = A_after_stop + horizon`, i.e.
the same thing with `B` replaced by `0.030`: **+~29 ms typical.** §4's transient-gap-for-permanent-
offset trade is therefore paid at ~30 ms, not at the 0.35 s the cap-based budget would have cost.

**Rejected: `horizon = maxStartLeadSeconds` (use the bound directly).** Always correct, never
overruns, needs no forecast — and it costs every recovery a ~0.5 s dropout plus a ~0.5 s playhead
plateau, on every device change, forever, to buy accuracy the forecast already delivers in every
measured sample. The 0.5 cap bounds a pathological case; it is not a value to pay routinely.

**Rejected: adaptive feedback on B.** B's variation is preemption of a synchronous block. The last
preemption does not predict the next one, so an adaptive term keyed on it is a filter over noise with
a state variable, a seed question and a staleness question attached. §8 Step 3's feedback path is
**deleted**, not parameterised. (§8's decision rule mechanically routes to "adaptive"; the rule asked
the right question about the wrong quantity, as the bs-1 preamble already records.)

### 13.3 The lead forecast — where `n` comes from, and why it errs safely

The circularity is real: beat → `scheduleAll` → `startablePlayerCount` → lead → anchor → beat. It is
broken by observing that the count needed is bounded by a count that is available BEFORE the cycle.

**The decision: read `graph.startablePlayerCount` at recovery entry.** In the common case it is not
an estimate of `n_resume` but an **upper bound** on it, and an upper bound is exactly what an
asymmetric loss function wants.

**Why it is an upper bound (verified in source, not assumed).**

1. `scheduleAll` (`PlaybackGraph.swift:2391`) walks every clip and drops it when
   `sourceStart >= fileLength` or `frameCount <= 0` (`:2434`, `:2438`). `sourceStart` grows with
   `startBeats` for any clip already in the past. So the enqueued SET is `{clips whose remaining
   source is non-empty at startBeats}`, which is **monotonically non-increasing in `startBeats`**, and
   recovery always resumes at a beat ≥ the outgoing schedule's beat.
2. The ledger is never cleared by natural completion: **`noteStopped()` has exactly ONE call site in
   the whole tree** (`PlaybackGraph.swift:3270`, inside `stopAllPlayers`) — grep-verified 2026-08-02.
   A player whose content ran out still reads `hasPendingSchedule == true`. So `n_entry` counts the
   full set the last schedule enqueued, including clips `scheduleAll` will now drop.
3. Under a live loop the head pass truncates at the loop end and `topUpLoopCycles`/`enqueueLoopCycle`
   re-enqueue whole cycles onto the same nodes (`PlaybackGraph.swift:2752-2769`), and `startPlayers`
   reads the count AFTER the top-up (`:3088`, comment at `:3074`). So the loop case converges to
   "every clip intersecting the loop window" independently of the resume beat: equality, not growth.

**The named exceptions — growth is possible, rare, and bounded.** These do not break the design; they
are why clamp-forward stays and why the allowance also buys count headroom.

- **Loop DISABLED mid-roll without a reschedule.** The outgoing schedule carries a loop window; the
  recovery builds a LINEAR schedule and can enqueue clips past the old loop end. `n_resume > n_entry`.
- **A node added to the graph without a reschedule.** New nodes start `hasPendingSchedule == false`,
  so they are invisible to `n_entry` but `scheduleAll` will enqueue them. Normal edits route through
  `tracksDidChangeBody → restart`, which re-enqueues and refreshes the ledger, so this needs a path
  that adds a node while rolling and does not restart.
- **bs-3's rewire-resume site**, which runs BECAUSE tracks changed. Not bs-2's site; the contract must
  simply not ASSUME constancy, and it does not.

Each unforeseen player costs 8 ms of unpredicted lead, so the 30 ms allowance absorbs **three** of
them before an overrun, and an overrun costs only its own magnitude.

**The alternatives, evaluated.**

| option | accuracy | coupling | verdict |
|---|---|---|---|
| **Read `startablePlayerCount` at entry (CHOSEN)** | exact upper bound in the common case; over-predicts by 8 ms per dropped clip | reuses the same accessor and the same formula; nothing new is computed | **adopted** |
| Reuse the previous start's measured lead (`lastStartLeadSecondsForTesting`) | ≈ the same number — it is `lead(n_entry)` from the last schedule — but STALE | worse: production would consume a `…ForTesting` seam whose own doc says production never branches on it | rejected; it is the chosen option with a staleness bug and a convention violation |
| Predict the pending-player count caller-side from the model | could be exact | requires re-implementing `scheduleAll`'s drop guards — the "model-level re-derivation of the six schedule guards" `PlaybackGraph.swift:103-115` explicitly refuses; a guaranteed second home | rejected on the one-home rule |
| Anchor contract carries the lead back out (closure / two-phase) | exact | `scheduleAll` needs the beat before the lead exists; a beat re-derived after the schedule desyncs the schedule origin from the anchor — §2 violated, §3.2's failure class | rejected |
| Run `scheduleAll` twice (fixed-point) | near-exact | doubles B, and the first pass has enqueue side effects | rejected |
| Use the bound (0.5) directly | exact, never overruns | none | rejected on cost (§13.2) |
| Hoist `startablePlayerCount` above `scheduleAll` inside `startPlayers` | — | **trap**: at that point the ledger is post-`stopAllPlayers` and reads 0, silently zeroing the m19-f lead scaling for every start | rejected; named because it looks like "move two lines up" |

⚠️ **THE LANDMINE OF THIS ITEM.** If the count read moves below `graph.stopAllPlayers()`
(`AudioEngine.swift:3388`) it reads 0, the horizon collapses to `0.06 + 0.030`, and recovery
under-predicts by up to 0.44 s on a large project — a silent, PROJECT-SIZE-DEPENDENT regression that
the one-clip fixture cannot see. Leg **L3** (§13.7) exists solely to catch this, and it catches it
with ONE audio clip because it asserts the reported COUNT rather than the horizon.

### 13.4 One home for the lead: `Sources/DAWEngine/StartAnchorBudget.swift`

**Renames §9.1's proposed `ContinuationAnchorBudget.swift`** — the file now owns the lead formula used
by EVERY start, not only continuations, and a name that says "continuation" would invite a second
copy for the normal path.

```swift
enum StartAnchorBudget {
    struct Lead { let seconds: Double; let wasCapped: Bool }
    static let leadFloorSeconds = 0.06
    static let leadCapSeconds = 0.5
    static let scheduleAllowanceSeconds = 0.030
    static func lead(forStartablePlayerCount n: Int) -> Lead
    static func continuationHorizonSeconds(forStartablePlayerCount n: Int) -> Double
}
```

- `Lead.wasCapped` exists so `startPlayers` can keep its existing stderr cap warning (`:3091-3097`)
  **without** re-evaluating the pre-cap expression — one computation, two consumers.
- `AudioEngine.swift:415` / `:419` become **forwarding aliases**
  (`private static let startLeadSeconds = StartAnchorBudget.leadFloorSeconds`), not copies. That keeps
  the three unrelated floor readers (`:2111`, `:2122`, `:2133`, `:2285`, `:2290` — the metronome
  enable-mid-play and reference re-anchors) untouched while making divergence unrepresentable. A full
  rename of those five sites is optional cleanup, explicitly NOT bs-2 scope.
- `AudioEngine.swift:3089-3097` becomes a call to `StartAnchorBudget.lead(...)` plus the existing
  warning. `lastStartLeadSecondsForTesting` keeps its meaning (post-cap).
- `Tests/DAWEngineTests/StartAnchorBudgetTests.swift` — **headless, no device**: floor at n ≤ 5, the
  8 ms/player slope, the cap at n ≥ 60, monotonicity, and `horizon(n) == lead(n) + allowance`.
- Add `StartAnchorBudget` **and** `AudioEngine.StartAnchorPolicy` to the ONE-home registry at close-out.
- ⚠️ `0.030` carries its derivation in its doc comment, with the two numbers that would change it:
  **bs-1's full-suite worst B = 20.2 ms** (×1.5) and **the 8 ms/player of count headroom it also buys**.
  If field overruns become common, THIS is the number to raise — never the accuracy it protects.

### 13.5 The clamp, both sides, and the seams

At the anchor site (both branches) the instant is chosen ONCE:

```
earliest = <today's expression>                       // clickAnchor + countInHostTicks
switch anchorPolicy {
case .asSoonAsPractical:  anchorHost = earliest       // byte-identical to today
case .atHostTime(let target):
    if target < earliest { anchorHost = earliest; continuationOverrunCount += 1; lastOverrun = …; stderr }
    else if target - earliest > hostTime(forSeconds: leadCap + allowance) {
        assertionFailure(…); anchorHost = earliest + hostTime(forSeconds: leadCap + allowance)
        continuationClampDownCount += 1; stderr
    } else { anchorHost = target }
}
```

**The upper guard is new in §13** and it is not symmetric with the lower one: clamping DOWN
reintroduces a backward step, so the real guard is the debug `assertionFailure` (a caller bug fails
loudly in tests) and the release clamp exists only to bound user-visible damage to a ~0.53 s dropout
instead of an unbounded one. Say that in the code comment; a future reader will otherwise "simplify"
the two clamps into one `clamp(...)` and lose the distinction.

**Seams to export** (raw scalars, `internal`, `private(set)`, production never branches on them):
`anchorLineForTesting: (startBeats: Double, anchorHostTime: UInt64)?`,
`continuationOverrunCountForTesting`, `lastContinuationOverrunSecondsForTesting`,
`lastContinuationHorizonSecondsForTesting`, `lastContinuationPlayerCountForTesting`.
**FORBIDDEN, per §9.1, restated because it is the seam a reader will want:** any in-engine
anchor-DIFFERENCE. Under the fix it recomputes the fix's own expression and subtracts it from itself
— identically zero by algebra, green against a broken `TempoMap`.

### 13.6 The blind spot no property witness covers: `clickAnchorHost`

In the untrusted branch the metronome anchors on `clickAnchorHost`, not `anchorHost`
(`AudioEngine.swift:3135`, `:3146-3148`). An implementation that sets `anchorHost = target` and leaves
`clickAnchorHost = anchorSampledHost + leadHostTicks` desyncs the CLICK from the transport by exactly
the over-prediction (~30 ms typical) — **and `anchorLineForTesting` reads the transport pair, so every
leg in §13.7 stays green.** Required shape, both branches:

```
let clickAnchorHost = anchorHost - countInHostTicks     // ≡ anchorHost under the §7 countInBars == 0 precondition
```

Written as the subtraction rather than as `= anchorHost` so the two branches keep identical algebra
and the line survives if the count-in precondition is ever relaxed. `startReferenceWithRoll(anchorHost:)`
already takes the chosen value directly and needs no change. **Pin this in
`StartAnchorPolicySiteTests` as a source assertion** (the click anchor is derived from the chosen
anchor, not from `anchorSampledHost`) rather than inventing a live metronome-timing leg.

**Trusted-branch landmine (§8 Step 2), with one correction.** Under `.atHostTime` the sample offset
must derive from `anchorHost − renderTime.hostTime`, not from `startLead`. ⚠️ **Do not rewrite the
`.asSoonAsPractical` path to use the host-delta form "for symmetry"** — it is algebraically equal but
round-trips through `hostTime(forSeconds:)` and is therefore not byte-identical, which forfeits the
`.asSoonAsPractical` = "today verbatim" claim that makes the null case reviewable. Two expressions,
one per policy, with a comment saying why.

### 13.7 Verification — the legs, their mutants, and their device needs

Every leg names the mutation that makes it RED. A leg that cannot fail is not a leg.

| # | leg | device? | RED under |
|---|---|---|---|
| **L0** | `StartAnchorBudgetTests` — floor / slope / cap / monotonicity / `horizon == lead + allowance` | **no** | any edit to the formula or the constants |
| **L1** | **Anchor-line continuity (THE regression guard, property witness)** | yes | reverting to entry-derivation: ≈0.26 beats vs ε≈1e-3, ~260× |
| **L2** | Overrun consistency, NEVER skipped | yes | a wrong derivation that is not reported as overrun (wrong map, wrong loop branch, wrong sign) |
| **L3** | **Forecast-source read-back — the COUNT, against the test's own snapshot** | yes | moving the count read below `stopAllPlayers` (engine reports 0 where the snapshot says n) |
| **L4** | Loop-wrap continuity (§9.3, unchanged) | yes | deriving inside `startPlayers` after `loopContext = nil` — the §5.1 mistake, and this is the ONLY automated catch |
| **L5** | `StartAnchorPolicySiteTests` — six-site table, `parameterHasNoDefault`, click-anchor derivation | **no** | a new call site defaulting the policy; a click anchor rebuilt from `anchorSampledHost` |
| **L6** | `RecoveryPlayheadTests` ceiling 1.2 → 0.25 + in-run delta (corroboration only) | yes | the unfixed tree: recover-only 0.268, restart 0.362–0.383 |

**L1 — the property witness.** Protocol as §9.1 (constant 120 BPM, loop off, ~500 ms roll, read
`(b0,h0)`, `watchdogRestart()`, read `(b1,h1)`, require `recoveryRestartCountForTesting` 0→1 as the
m23-bt discriminator), assertion computed test-side:
`abs(b1 − (b0 + 2.0·AVAudioTime.seconds(forHostTime: h1 − h0))) <= ε`.
Healthy path: `h1` is an INTEGER COPY of the `H` that `b1` was derived for, so the residue is one
host-tick→seconds→beat round trip. Epsilon discipline exactly as §9.1: `1e-3` placeholder with
`// TIGHTEN ME`, print the measured value every run, tighten to measured-worst × 10 at close-out,
expect ~1e-6, and treat anything above 1e-4 as a precision problem to understand rather than a
tolerance to widen. **Skips (loudly) when the overrun counter is non-zero** — and L2/L3 are what stop
that skip from becoming a coverage hole.

**L3 — the leg §9.1 did not have, and the one this section most needs. THE DISCRIMINATOR IS THE
COUNT, NOT THE HORIZON.** Assert
`lastContinuationPlayerCountForTesting == nSnapshot`, where `nSnapshot = engine.graph.startablePlayerCount`
is read by the TEST immediately before the bounce (`graph` is `private(set) var`, so `@testable`
reaches it). The count-source mutant — the read moved below `stopAllPlayers()` — then reds at
**n ≥ 1**: the engine reports 0 where the snapshot says n, with no floor-clamp masking and nothing to
compute. Anti-vacuity is therefore `nSnapshot >= 1`, and it must be asserted with its reason: an
ALL-MIDI fixture reads 0 on both sides and proves nothing, because `startablePlayerCount` walks
`trackNodes` (AUDIO clip nodes) while instrument tracks live in `instrumentNodes` — the same trap
bs-1's header names. One audio clip in the FUTURE (bs-1's beats 4…28 convention, or `scheduleAll`
drops it at the resume beat) and a ~200 ms roll suffice; the property is roll-duration-independent.

⚠️ **An earlier draft of this leg keyed on the HORIZON and therefore demanded a ≥ 6-audio-clip
fixture** (below 6 the lead is pinned at the 0.06 floor, so a horizon assertion cannot tell the mutant
from the correct implementation). That fixture is a new live session, which §13.8 has just committed
not to add. **The decomposition to write down, so the next reader does not reinstate the big
fixture:** *L0 owns the formula* (slope, cap, monotonicity, headless, no device) and *L3 owns the read
site*. Keep the horizon identity
(`lastContinuationHorizonSecondsForTesting == StartAnchorBudget.continuationHorizonSeconds(forStartablePlayerCount: nSnapshot)`)
as a SECOND assertion in the same leg — it subsumes §9.1's anti-degenerate assertion 3 (a budget ≡ 0
fails it) with an exact identity rather than a range check — but say in the leg's comment that it is
not required to be non-vacuous at low n, because L0 carries that burden.

**The assumption L3 rests on, stated so a future change fails loudly rather than blindly:** the
test's snapshot is comparable to the engine's entry read only because the enqueue ledger survives
`engine.stop()`. `noteStopped()` is called from `stopAllPlayers()` alone (grep-verified,
`PlaybackGraph.swift:3270`), and `watchdogRestart` reaches `graph.stopAllPlayers()` only AFTER the
count read. If that ever changes, L3 goes spuriously RED rather than silently blind — the right
failure direction, but only if someone knows why.

**L2** — `abs(b1 − (b0 + 2·Δt)) <= reportedOverrunBeats + ε`, unconditional. It relates two
independently exported quantities, so it holds regardless of load or which path ran.

**Retired from §9.3: the gap-bound assertion.** §9.3 proposed asserting the silent gap against
`maxContinuationBudgetSeconds + slack`. Drop it. The gap is `A_after_stop + horizon`; bs-2 does not
touch A, and L3 pins the horizon EXACTLY — so the threshold version adds a guessed millisecond bound
that can only catch what an exact read-back already catches. **PRINT the gap** (`[measured] m23-bs-2
gap=… ms`) for the record and assert nothing about it. Replacing a threshold with a read-back is the
property-witness principle applied to this design's own verification.

**L6 — the ceiling, corrected for δ.** §9.6's falsifiable prediction was "all three legs converge on
≈0.12". **That is wrong by β·δ and the corrected prediction is `control + 2·δ` ≈ 0.148 on this
machine** (§13.1). Keep the ceiling at **0.25**: it is the largest round number below the unfixed
tree's recover-only 0.268, so it still kills the mutant, and 0.25/0.148 = 1.7× is the flake margin.
⚠️ **The margin is buffer-size dependent through δ** — at 1024 frames the expected value is ~0.17 and
at 2048 frames ~0.21, which would leave almost nothing. Put that in the header: on such a machine the
ceiling must be **re-derived** (`(control + 2·δ) × 1.7`), not bumped. The in-run delta leg gets the
same treatment: expected `2·δ` ≈ 0.028 here, so either keep `<= 0.10` with the dependence documented,
or (sharper, and self-calibrating across hardware) measure δ test-side once per suite via a throwaway
engine and assert `delta − 2·δ <= 0.06`, printing δ and its buffer+latency cross-check alongside.
⚠️ **Do NOT read `hasSampleAnchor` from the new legs to decide whether δ applies** — it has exactly
ONE reader by design (m23-bq, machine-asserted by `RenderClockTrustSiteTests`); print and tolerate
both cases instead.

**Anti-vacuity mutants (mandatory), run filtered and recorded in the file header:**
(a) revert `recoverEngine` to entry-derivation → **L1 must redden**;
(b) move the count read below `stopAllPlayers()` → **L3 must redden at n ≥ 1, L1 must NOT** (it is a
budget error, not a derivation error — that split is the point of having both);
(c) budget ≡ 0 → **L3 reddens, L1 skips** (proving the skip is bounded);
(d) make the clamp unconditional (`anchorHost = target`, no `max`) → **nothing may redden**, proving
the suite does not falsely claim to cover the past-anchor case, which is prevented by construction;
(e) derive inside `startPlayers` → **L4 reddens, L1 stays green**.

**Regression surface** (unchanged from §9.7, plus one): `RenderClockTrustSiteTests`,
`NoteChaseSiteTests` (the §8 Step 5 formatting collision is the EXPECTED first failure if Step 5 is
skipped), `RecoveryOutputPinGateTests`, `RecoveryPlayheadTests`, `EngineWatchdogTests`,
`RecoveryCostSplitTests` (its seams still fire; only its gating changes), plus a full
`./scripts/test.sh` **backgrounded (~90 s) with `grep '^✘'` — the script EXITS 0 on a failed run.**

### 13.8 Contention — the sharing story, decided

Three live-playback suites contending for one physical output device is the condition behind the
`GaplessLoopTransportTests` `(wraps → 0) >= 1` flake. `.serialized` does not scope across suites
(m23-bu-1). **bs-2's rule: it must not increase the number of live playback sessions a default full
run performs.** Two moves, and the implementer must VERIFY the counts by running, not by trusting
this table:

1. **Declare L1–L4 in `extension RecoveryPlayheadTests`**, in a new file
   `Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift`. Tests declared in an extension of a
   `@Suite` type belong to that suite, so they inherit its `.serialized` — one suite, no intra-file
   contention, and the file stays readable. ⚠️ **Verify the inheritance in the first run** (filtered,
   check the printed test count and that no two live legs interleave); the named fallback is to move
   the tests into `RecoveryPlayheadTests.swift` itself. ⚠️ And be honest about the scope: this removes
   contention WITHIN that suite only. `GaplessLoopTransportTests` still runs in parallel with it.
2. **Env-gate `RecoveryCostSplitTests` entirely** behind `DAWPRO_M23BS_COSTSPLIT=1`, with a printed
   skip line in the `NO OUTPUT DEVICE` idiom so the skip is VISIBLE (m20-j's two unrun audible legs are
   the counter-example: a silent skip looks exactly like coverage). Justified, not merely convenient:
   its own header says "nothing here is a regression guard for a fix"; its findings are already written
   into that header and into this document; and after bs-2 production reads `graph.startablePlayerCount`
   LIVE rather than any `…ForTesting` seam, so nothing bs-2 depends on loses coverage. Keep the file —
   it is how the numbers get re-measured on other hardware.

**Session budget: today ≈ 3–4 (`RecoveryPlayheadTests`) + 6 (`RecoveryCostSplitTests`, 2 shapes × 3
bounces) ≈ 9–10. After bs-2: ≈ 3–4 + 0 + 2–3 (L1, L3, L4; L2 rides L1's session) ≈ 5–7.** Strictly
fewer, with the arithmetic shown so a reviewer can check it rather than believe it. If the
implementer's own count comes out higher, that is the signal to gate more, not to proceed.

**Not chosen:** a cross-suite serialization token (nesting the live suites under one `.serialized`
parent). It would work and it is the eventual right answer, but it restructures three suites bs-2 does
not otherwise touch. Record it as the remedy if the flake survives the session-count reduction.

### 13.9 Corrections to §1–§12 — named here, not edited there

1. **§8 Step 3 is superseded in full** by §13.2. Its `lastScheduleCost * safetyFactor` term is keyed on
   noise; its feedback path is deleted rather than retuned.
2. **§9.1's file name** `ContinuationAnchorBudget.swift` → **`StartAnchorBudget.swift`** (§13.4).
3. **§9.1's anti-degenerate assertion 3** (horizon within `[floor, cap]`) is replaced by L3's exact
   identity against `StartAnchorBudget`, which is strictly stronger and catches the count-source bug a
   range check cannot see.
4. **§9.3's gap-bound assertion is retired** in favour of printing (§13.7).
5. **§9.6's prediction "all three legs converge on ≈0.12" is wrong by `2·δ`.** Corrected value
   ≈0.148 on this machine, buffer-size dependent. The ceiling 0.25 survives; its justification changes
   from "converges on control" to "converges on control + 2·δ, and the property leg does the killing".
6. **The bs-1 preamble's item 5** ("the residual is not a constant to hardcode — DERIVE it from
   `presentationLatency` + buffer duration") is right about the prohibition and wrong about the
   destination: the derived quantity belongs in the TEST's expected value, not in the budget (§13.1).
   Its two hypotheses (a) and (b) are one mechanism, not competitors.
7. **The bs-1 preamble's block-quoted lookup proposal** is refuted as the roadmap records — and the
   refutation's own conclusion ("every recovery is a forecast") understates the position: the entry
   count is a forecast that is provably an upper bound except at three named sites (§13.3).
8. **§8's `resumeBeat(at:anchor:)`** must keep §5.2's loop-end snap (derived beat `>= loopEndBeat`
   under an active loop → snap to `loopStartBeat`), and the new derivation instant makes that guard
   more reachable, not less.

### 13.10 What I am NOT confident about

- **That `n_entry ≥ n_resume` holds on every path.** Three counterexamples are named (§13.3) and I
  expect there are more; the argument rests on `scheduleAll`'s drop guards, on `noteStopped()`'s single
  call site, and on the claim that every node-adding path reschedules. The first two are grep-verified;
  the third is an inference from `tracksDidChangeBody → restart`. **Clamp-forward is what makes being
  wrong here cost a counted 8 ms per surprise instead of a defect.**
- **The exact value 0.030.** It covers bs-1's measured worst by 1.5× on one machine, over 32 samples,
  in one thermal state. It is a safety margin, not an assertion threshold — missing it is counted and
  printed and degrades to today's behaviour — but I have no basis for calling it right on other
  hardware.
- **δ's mechanism.** The algebra in §13.1 reproduces bs-1's residual in magnitude, constancy, project-
  independence and bounce-independence, which is four independent agreements. It is still a derivation
  from a model of what `lastRenderTime.hostTime` means, and bs-1 could not obtain a second buffer size
  read-only. **The direct measurement is what makes this safe: if the mechanism is wrong, the direct δ
  read is still the right number for the test's expectation.**
- **Whether `.serialized` is inherited by tests declared in an extension of the suite type.** Stated as
  a check with a named fallback, not as a fact.
- **The 0.25 ceiling on hardware with a larger I/O buffer.** It is fine here and I have flagged where it
  stops being fine, but nobody has run it there.
- **Whether the fix makes the recovery FEEL better.** It removes a permanent timing error and adds ~30 ms
  to a transient dropout. I believe that trade is right (§4) and it is unverified by any human listening
  test. bs-4 (playhead continuity through the gap) is what makes it also LOOK right.

### 13.11 Implementation order (bs-2)

1. `Sources/DAWEngine/StartAnchorBudget.swift` — new, pure, headless. `Tests/DAWEngineTests/StartAnchorBudgetTests.swift` (L0). Green before touching the engine.
2. `Sources/DAWEngine/AudioEngine.swift:415/:419` → forwarding aliases; `:3089-3097` → `StartAnchorBudget.lead(...)` + the existing cap warning. **Null-case check: `lastStartLeadSecondsForTesting` unchanged on every existing leg.**
3. `AudioEngine.StartAnchorPolicy` near `PlaybackAnchor` (`:157`), **no default** on `anchorPolicy:`; six call sites per §8's table; §8 Step 5's formatting exactly (`cause: cause` stays on the `startPlayers(` line, `renderClockTrusted` on the continuation line) or `NoteChaseSiteTests` reds.
4. Anchor site: one chosen instant, both clamps, `clickAnchorHost = anchorHost − countInHostTicks` (§13.6), the trusted-branch sample offset for `.atHostTime` only (§13.6), the new seams (§13.5).
5. `recoverEngine`: count read at entry **before** `stopAllPlayers()`; `resumeBeat(at:anchor:)` generalised from `:3378-3385`; derivation after segment A, immediately before the call (§5.1); `lastKnownBeats` untouched (§6).
6. `Tests/DAWEngineTests/StartAnchorPolicySiteTests.swift` (L5) — headless, mirrors `RenderClockTrustSiteTests`.
7. `Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift` (L1–L4) as `extension RecoveryPlayheadTests`; verify `.serialized` inheritance.
8. `RecoveryPlayheadTests` header + ceiling (L6, §13.7) — and **re-derive the `rollMs >= 3 × maxLagBeats-as-time` paragraph**: at 0.25 beats the floor is 375 ms, so the existing 2000 ms keeps **5.3×** margin. Write 5.3×. ⚠️ **§9.6 itself now contains an instance of the very hazard it names** — its closing paragraph still says "3.3×", computed for the withdrawn 0.4-beat ceiling. A stale margin beside a changed number is how the m23-bq guard gets disarmed.
9. Env-gate `RecoveryCostSplitTests` (§13.8) with a printed skip.
10. Run the five mutants (§13.7), record their numbers in the new file's header, tighten ε, then a full backgrounded suite with `grep '^✘'`.

**Close-out:** tick the roadmap, ORCH record, CHANGELOG, memory patch with re-measured baselines, add
`StartAnchorBudget` + `AudioEngine.StartAnchorPolicy` to the ONE-home registry, and add §12's
`docs/ARCHITECTURE.md` entry **amended with §13.1's sentence** (write the tempo factor as `β·δ`, not
`2·δ` — the literal 2 is this fixture's 120 BPM and that entry is read outside this context): *the
~14 ms step that remains at the seam is the render-clock lead δ (β·δ in beats) — a change of playhead
display basis, not lost transport time, and adding it to the resume beat would trade a display
discontinuity for an audio one.*

---

## §14 — m23-bs-3 DESIGN (the remaining continuation sites)

**Status:** design complete 2026-08-02 (`daw-architect`), written AFTER m23-bs-2 landed and was
verified. **This section is authoritative for bs-3 and it does not edit §1–§13** — where something
there is now wrong, §14.11 names it. §13 remains authoritative over §8–§12; §14 stands on §13.
**No full Xcode required:** no entitlements, no AUv3, no code signing — plain `swift build` and
`./scripts/test.sh`.

**Line numbers in this section were read from the post-bs-2 tree on 2026-08-02.** Re-grep before
editing; bs-3's own edits will move them again.

### 14.0 What bs-2 left standing, and the one thing it did not solve

bs-2 shipped the mechanism: `AudioEngine.StartAnchorPolicy` (no default), `StartAnchorBudget` as the
one home of the lead and the continuation horizon, `resolveAnchorHost` as the one place an instant is
chosen, `resumeBeat(at:anchor:)` as the one derivation, and `recoverEngine` fixed (recover-only lag
0.268 → 0.144 beats, restart 0.383 → 0.144, control 0.117, continuity residue 0.000e+00).

bs-2's mechanism has a precondition it satisfies at `recoverEngine` and **cannot satisfy at the other
three sites: it needs a LIVE ANCHOR.** `recoverEngine` still holds one (`guard let anchor =
currentAnchor`, `:3664`), so it can evaluate that anchor's line at a predicted instant. The rewire
and rebuild resumes hold only

```swift
private var resumeAfterRoutingRewire: (beats: Double, tempoMap: TempoMap)?   // :493
```

captured at `:624` (the `willMutateRoutingTopology` hook) and `:1047` (`rebuildEngine`'s own quiesce)
as `(beats: derivedBeats(), tempoMap: anchor.tempoMap)`. **That is a FROZEN BEAT.** The anchor it came
from is gone, and an arbitrary amount of work runs before the resume. Handing `.atHostTime(H)` a
frozen beat would anchor a STALE beat at a NEW instant — not the fix, the m19-f shifted-origin hazard
dressed as one. `restart`'s continuation callers have the same problem in miniature: they compute
`derivedBeats()` before entry and `restart` then runs `stopAllPlayers()` plus all of segment B plus
the lead before the anchor lands.

So bs-3 is not "flip three enum values". It is: **give every continuation site something it can
RE-DERIVE from, and make the frozen beat structurally impossible to reintroduce.**

---

### 14.1 THE PRODUCT QUESTION — does wall time keep running through a cold rebuild?

**Decision: YES. Every continuation site re-anchors the OUTGOING line at the instant it actually
resumes. The song resumes where wall time says it is, not where it left off.** This applies to the
rewire resume, the rebuild resume and every `restart` continuation, identically to `recoverEngine`.

**Why, in one sentence that is the whole argument:** during the gap nothing was rendered, so under
this answer *the gap you heard and the distance you travelled are the same duration*, while under the
alternative they diverge — permanently, and compounding on every occurrence.

The five supporting reasons, strongest first.

1. **The alternative is not "position continuity", it is an uncounted permanent desync that
   ACCUMULATES.** Freezing the beat and re-anchoring it later shifts the transport's whole
   beat↔wall-time line backward by the gap, for the rest of the roll. Nothing ever re-syncs it. Add
   three sends while the transport rolls → three rebuilds → the transport is permanently N hundred ms
   behind, and the error is invisible because the playhead never moves backward on screen; it
   PLATEAUS and then resumes. bs-2 removed this for one path. The path bs-3b fixes (`restart`, via
   `tracksDidChangeBody:976`) fires on **every piano-roll note edit and every clip move while
   rolling** — so today the class is alive on the most frequent path in the tree, at ~0.15 beats a
   time, cumulative.

2. **The concept is already defined and a per-site answer would dissolve it.** `StartAnchorPolicy`'s
   own doc comment (`AudioEngine.swift:183-186`) defines CONTINUATION as *"wall time kept running
   through an engine bounce, so the beat is a FUNCTION of the instant."* A rewire or rebuild resume
   under a rolling transport IS an engine bounce under a rolling transport. If these sites answer
   differently, the enum stops being a law about two kinds of start and becomes a bag of per-site
   preferences — which is exactly the state m23-bp, m23-bq and bs-2 each spent an item escaping.

3. **Everything that did NOT bounce kept running in wall time.** The playhead handler feeds
   `ProjectStore`, which is what the UI and the control plane read (`transport.positionBeats` is what
   an agent sees). `InputCapture` runs on its OWN `AVAudioEngine` and is not touched by an output-graph
   rebuild. ⚠️ **The recording half of this argument is a NAMED UNKNOWN, not evidence** — I have not
   verified that a rebuild mid-take is reachable, nor what it does today (`willMutateRoutingTopology`
   does not consult `activeTake`, and `rebuildEngine` does not either). If it is reachable, freezing
   the beat mis-places recorded material by the rebuild duration and that is a correctness bug; if it
   is already broken, it is evidence for neither answer. **Filed in §14.12; do not cite it as settled.**

4. **There is no duration past which the other answer becomes right, and pretending there is would
   cost a magic threshold.** A duration-keyed policy switch is a second law with an unpinnable
   constant, and it is not representable in the enum. If the product ever wants "the gap was too long,
   stop instead of resuming", that belongs at the STORE and is expressed as *stop playback*, not as a
   different anchor policy. The engine's contract stays: **if you resume, you resume on the same line.**

5. **The 8-second-device-unplug scenario is not this path, and bs-3 does not create it.**
   `rebuildEngine` is synchronous on the main actor; `engine.start()` either succeeds now or throws,
   and on a throw `isRunning` stays false, the resume block is skipped and the transport is silently
   dropped (existing behaviour, `:1176`). A device that is *gone for seconds* lands on
   `handleConfigurationChange`/the watchdog → `recoverEngine`, which already answered "wall time kept
   running" and whose `catch` deliberately reports the stop-instant beat (§6). So the hypothetical is
   answered elsewhere, consistently, and bs-3 changes nothing about it.

**Traced consequence, accepted (advisor's catch).** `rebuildEngine` runs
`graph.applyParameters(tracks:playheadBeat: lastKnownBeats)` twice (`:1128`, `:1155`), keyed to the
quiesce beat, while the transport now resumes LATER. Those passes therefore publish automation values
for a beat slightly behind the resume beat, for the few ms between them and the resume. It
self-corrects immediately: `scheduleAll` re-origins `stagedAutomationStart = (startBeats, tempoMap)`
(`PlaybackGraph.swift:2397`) at the resume beat, so the staged timeline is right from the first
rendered sample. §14.2's `lastKnownBeats` change makes those passes FRESHER than today, not staler.

**Alternatives, named so nobody re-opens them silently.** (i) *Freeze the beat (today).* Loses on
§14.1.1 — uncounted, permanent, cumulative. (ii) *Freeze the beat but resume the WALL CLOCK too*, i.e.
treat the gap as a pause and shift every subsequent wall-time reading. Not expressible: the host clock
is the machine's, shared with the capture engine, the writer's accept window and every `AVAudioTime`
the SDK consumes. (iii) *Duration-keyed hybrid.* §14.1.4.

---

### 14.2 THE RESUME STATE — carry the outgoing anchor's LINE, and nothing else

**Decision: replace the frozen-beat tuple with the host-domain projection of the outgoing anchor.**

```swift
/// One anchor's line in the HOST domain — the beat, the instant that beat
/// occurs at, and the map that connects them. Everything a continuation needs
/// to re-derive its resume beat for an arbitrary future instant, and NOTHING
/// that stops being meaningful when the engine object is replaced.
struct AnchorLine {
    let startBeats: Double
    let tempoMap: TempoMap
    let anchorHostTime: UInt64
}
```

with `PlaybackAnchor` gaining `var line: AnchorLine { AnchorLine(startBeats:, tempoMap:,
anchorHostTime:) }`, `resumeBeat` narrowed from `(at:anchor:)` to `(at:line:)`, and

```swift
private var resumeAfterRoutingRewire: (line: AnchorLine, startablePlayerCount: Int)?
```

(the second field is §14.3). `recoverEngine` passes `anchor.line`; the two resume sites pass the
carried one. **One derivation, one home, at four sites.**

⚠️ **NAME COLLISION, verified 2026-08-02 — declare it `private` and NESTED IN `AudioEngine`, beside
`PlaybackAnchor` (`:157`).** `RecoveryAnchorContinuityGateTests.swift:108` already declares a
`struct AnchorLine` inside `extension RecoveryPlayheadTests` (the test's own raw (beat, host) pair).
A MODULE-SCOPE `AnchorLine` in `DAWEngine` would be shadowed by that one inside the extension — the
test would keep compiling while silently meaning something else, and any future test wanting the
engine type would have to spell `DAWEngine.AnchorLine`. Nesting it privately inside `AudioEngine`
removes the collision entirely: every consumer (`resumeAfterRoutingRewire`, `resumeBeat`,
`PlaybackAnchor.line`, all four call sites) is inside `AudioEngine` already. Register it as
`AudioEngine.AnchorLine`.

**Why the LINE and not the ANCHOR.** `PlaybackAnchor` also carries `anchorSampleTime`,
`outputSampleRate` and `hasSampleAnchor` — fields whose meaning does not survive an engine
replacement. Carrying them across a rebuild makes representable precisely the state the m23-bq defect
was made of: a stale sample clock, still structurally valid-looking, available to be read against a
new render session. `resumeBeat` needs exactly three fields and the host clock is monotonic across a
bounce, so narrowing costs nothing and removes a whole failure class **by representability rather
than by comment** — the `ArrangeDropSnap` model.

**Alternatives.**

| option | cost | what it makes representable that shouldn't be | one-home verdict |
|---|---|---|---|
| **Carry `AnchorLine` (CHOSEN)** | one small value type; `resumeBeat` narrowed | nothing — the sample-domain fields are absent | `resumeBeat` stays THE derivation, now with four callers |
| Carry the whole `PlaybackAnchor` | smallest diff | a stale sample anchor and a stale `hasSampleAnchor`, both readable against a REPLACED engine — the m23-bq shape | same one home, but re-opens the class bs-2's twin item closed |
| Carry `(beats, tempoMap, quiesceHost)` and derive forward by elapsed wall time | looks cheapest | **three separate defects** (below) | **NO — it is a second derivation** |
| Keep the frozen beat; correct for elapsed time inside `startPlayers` | — | — | forbidden by §5.1 (post-`loopContext = nil`, the linear branch) and §9.1 |

**The `(beats, tempoMap, quiesceHost)` option fails on three counts and it is the one a reader will
propose, so all three are written down.**

1. **Mixed clock basis.** `b_quiesce` comes from `derivedBeats()`, which reads
   `elapsedSeconds(anchor:)` (`:3471`) and PREFERS the SAMPLE branch when `hasSampleAnchor`.
   `quiesceHost` is `mach_absolute_time()`. Composing them re-introduces the render-clock lead δ as a
   silent additive error — §13.1's entire subject, re-imported at the site bs-3 exists to fix.
2. **It needs its own loop arithmetic.** `beat(forElapsedSeconds:anchor:)` (`:3493`) measures the
   modular branch's `headSeconds` from the ANCHOR, not from quiesce. Deriving "quiesce beat + elapsed"
   requires re-implementing the wrap from a different origin — a second home for exactly the
   computation §5.1 and leg L4 exist to protect.
3. **Double-clamping.** `max(anchor.startBeats, …)` is applied once at quiesce and again forward; it is
   not idempotent across the modular branch.

**Also at both quiesce points: `lastKnownBeats = derivedBeats()` — the §6 mirror.** Today neither
quiesce site updates it, so a rebuild whose `engine.start()` throws leaves the transport reporting
whatever the last 30 Hz playhead push happened to be. `derivedBeats()` is already evaluated at both
sites today (it is what the tuple stored); assigning it to `lastKnownBeats` costs nothing, makes a
FAILED rebuild report a beat that actually sounded, and makes `rebuildEngine`'s two `applyParameters`
passes fresher. This is the same rule `recoverEngine` follows at `:3690` and it should be spelled the
same way, with the same comment: *the stop-instant beat, never the resume beat.*

**The pairing assumption, stated so a future change fails loudly.** `resumeBeat`'s modular branch
reads the ENGINE's `loopContext`, not the carried line's. That is correct **only because the carried
line and the surviving `loopContext` come from the same outgoing `startPlayers`.** It holds today for
two reasons, both verified: `loopContext` is written in exactly three places (`:686`
`windDownAfterException`, `:857` `stopPlayback`, `:3185` `startPlayers`) and none of them runs between
quiesce and resume; and every quiesce→resume path is one synchronous main-actor stretch
(`tracksDidChange` → `reconcile` → hook → `rebuildEngine` → resume; and the AU path at `:1456-1463`,
whose only `await` precedes `invalidateInstrumentNode`, never separating it from the following
`tracksDidChange`). **Two cheap guards, both in bs-3a:** (i) a source pin that `loopContext` is
assigned in exactly those three places; (ii) a debug `assertionFailure` at each resume site if
`currentAnchor != nil` — a start that arrived between quiesce and resume would make the carried line
stale, and silently applying it is the failure this pairing can produce. No release behaviour change.

---

### 14.3 THE FORECAST SOURCE — the §13.3 landmine has a SECOND instance, and here it is the DEFAULT

§13.3's rule is "read `graph.startablePlayerCount` before `stopAllPlayers()`, because
`noteStopped()` zeroes the ledger". At `recoverEngine` obeying it means moving one line up. **At the
two resume sites the natural read site returns 0 and it is not even a mistake:**

- **rewire resume (`:999`)** — the hook already ran `graph.stopAllPlayers()` at `:628`. The ledger is
  zero before `tracksDidChangeBody` ever reaches the resume block.
- **rebuild resume (`:1184`)** — `graph` is a **different object**. `rebuildEngine` builds
  `PlaybackGraph(engine:graphRate:)` fresh at `:1112` and reconciles it; a graph that has never been
  scheduled has `hasPendingSchedule == false` on every node. The count reads 0 by construction.

So at both sites the horizon would collapse to `0.06 + 0.030` regardless of project size — §13.3's
"silent, PROJECT-SIZE-DEPENDENT regression invisible to a one-clip fixture", arrived at by writing the
obvious code.

**Decision: capture the count at QUIESCE, above `graph.stopAllPlayers()`, and carry it in the resume
state** (hence the tuple's second field). For `restart`, capture it at the top of `restart` itself,
above its own `stopAllPlayers()` at `:3113` — a third instance of the same landmine, in the one place
it can be fixed once for all five `restart` callers.

**The growth exposure is real here and it is §13.3's own third named exception.** The rewire resume
runs BECAUSE tracks changed, and the rebuild resume can build a materially different graph. So
`n_quiesce` is not an upper bound at these sites, and each unforeseen player costs 8 ms of
unpredicted lead against a 30 ms allowance (three players of headroom).

**What bounds it is that the failure mode is TODAY'S BEHAVIOUR.** An under-predicted anchor clamps
FORWARD, and a clamp-forward reproduces exactly the pre-bs-3 defect with a magnitude equal only to the
miss. In the worst imaginable case (`lead_actual` capped at 0.5, `lead_est` at the 0.06 floor) the
overrun is ~0.41 s — which is what that start costs *today, unconditionally, uncounted*. **So bs-3 is
monotone: at every site, in every regime, it is never worse than the tree it replaces, and usually
much better.** That is the safety argument for the whole item and it should be in the close-out.

**Verified, so it can be discounted rather than feared:** the project-boundary rebuild cannot hit the
"completely different project" case from the store, because `ProjectStore.openProject` and
`newProject` both call `stop()` when `transport.isPlaying` (`ProjectStore.swift:5610+`, `:5631+`)
before `projectWillReplace()`, so `currentAnchor` is nil and no resume state exists. **The engine
contract must not DEPEND on that** — it is the store's discipline, not the engine's invariant — but it
means the pathological count swing has no live caller today.

---

### 14.4 ONE HOME FOR THE CONTINUATION INSTANT — and a false-green it closes

Four sites would otherwise repeat "compute the horizon, write two seams, read the clock, add".

```swift
/// THE ONE PLACE a continuation start picks the instant it will anchor on
/// (m23-bs-3). Every `.atHostTime` caller comes here; the derivation of the
/// BEAT for that instant stays at the call site (§5.1).
///
/// ⚠️ `n` is a PARAMETER, deliberately: the READ SITE is the load-bearing
/// thing (§13.3) and it differs per caller — quiesce for the two resumes, above
/// `stopAllPlayers()` for `restart`, entry for `recoverEngine`. A helper that
/// read the count itself would move all four reads to one wrong place.
private func continuationAnchorInstant(startablePlayerCount n: Int) -> UInt64 {
    let horizon = StartAnchorBudget.continuationHorizonSeconds(forStartablePlayerCount: n)
    lastContinuationHorizonSecondsForTesting = horizon
    lastContinuationPlayerCountForTesting = n
    continuationStartCountForTesting += 1        // m23-bs-3: the per-EVENT discriminator
    return mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: horizon)
}
```

**`continuationStartCountForTesting` is not decoration — it closes a false-green bs-3 would otherwise
ship.** `lastContinuationHorizonSecondsForTesting` and `lastContinuationPlayerCountForTesting` are
written ONLY by `recoverEngine` today. A bs-3 leg that reads them after a rewire — in a `.serialized`
suite where a recovery leg already ran — reads the RECOVERY's values, and on a similar fixture those
can coincidentally equal the snapshot the leg is comparing against. A monotone counter, asserted to
advance by exactly 1 across the event, is the m23-bt `recoveryRestartCountForTesting` discriminator
applied to the same hazard. **Every bs-3 live leg asserts it.**

**`StartAnchorBudget` is unchanged by bs-3** — same lead, same allowance, same horizon. bs-3 adds
callers, not formulas. (One doc-comment amendment: §14.6.)

---

### 14.5 `restart` — forwarded parameter, or derived from `cause`? NEITHER

**Decision: `restart` takes a `RestartOrigin`, and derives the continuation beat itself, above its
call to `startPlayers`.**

```swift
private enum RestartOrigin {
    /// RELOCATION — the caller chose this beat; any instant will do.
    case beat(Double)
    /// CONTINUATION — wall time chose it. `restart` predicts its own anchor
    /// instant and derives the beat FOR that instant off this line.
    case continuing(from: AnchorLine)
}
private func restart(from origin: RestartOrigin, tempoMap: TempoMap, cause: RescheduleCause)
```

**Why neither of the two options in the brief.**

- **A forwarded `anchorPolicy` is a contract the caller cannot honour cheaply.** `.atHostTime(H)`
  asserts *"`fromBeat` was derived FOR H"*. `restart`'s continuation callers compute their beat before
  entry, so a forwarded `.atHostTime` is a lie unless each caller also predicts `H` — and each caller's
  `H` would then have to cover `restart`'s own `graph.stopAllPlayers()` (`:3113`), which happens AFTER
  the caller's clock read. That silently widens `StartAnchorBudget.scheduleAllowanceSeconds` past its
  §13.4 definition ("everything between `startPlayers` entry and the anchor") at four sites, and
  repeats a five-line ritual four times: the second-home hazard the whole design exists to prevent.
- **Deriving the policy from `cause` is worse, and not for the reason the brief anticipates.**
  Mechanically it forces `restart` to re-derive the beat internally and DISCARD the `fromBeat` its
  caller passed whenever `cause == .continuation` — a required argument silently ignored half the
  time. No amount of correlation between the two concepts makes that signature acceptable.

**Is the correlation a law or a coincidence? A COINCIDENCE — a fact about today's five call sites.**
`cause` answers *"does this schedule build chase held notes?"* (m23-bp). `anchorPolicy` answers *"who
chose the beat?"*. Both off-diagonal combinations are coherent and one is already under active debate
in this tree:

- **chase = YES with a caller-chosen beat.** This is m23-bv's open question verbatim: `render.bounce
  fromBeat:` is a caller-chosen beat where chasing a pad held from bar 1 is arguably wanted. The live
  twin would be a "nudge the playhead while rolling, keep the pad sounding" transport verb.
- **chase = NO with a wall-time-chosen beat.** The loop-wrap fallback (`:3567`) snaps to
  `loopStartBeat` and deliberately does not chase, but the musically correct position is
  `loopStartBeat + overshoot`, which is a function of wall time. Today it is a relocation for both
  questions by explicit design (the post-fallback state must equal "seek to loop start and play"); that
  is a decision that could be revisited without touching `cause` at all.

So collapsing them is a **latent bug**, not a simplification, and m23-bp's precedent stands: `cause`
stays a separate, required, forwarded parameter. `RestartOrigin` does something better than keeping
them apart — **it removes a way to be WRONG rather than a way to be INCONSISTENT.** The incoherent
pairing (a stale beat presented as derived-for-an-instant) becomes unrepresentable, and the coherent
off-diagonal combinations stay expressible.

**Shape inside `restart`.**

```swift
    private func restart(from origin: RestartOrigin, tempoMap: TempoMap, cause: RescheduleCause) {
        // ⚠️ §13.3, THIRD INSTANCE: above stopAllPlayers(), which zeroes the ledger.
        let startable = graph.startablePlayerCount
        graph.stopAllPlayers()
        currentAnchor = nil
        switch origin {
        case .beat(let beats):
            startPlayers(fromBeat: beats, tempoMap: tempoMap, renderClockTrusted: true, cause: cause,
                         anchorPolicy: .asSoonAsPractical)
        case .continuing(let line):
            // §5.1 CONFIRMED SAFE: this is inside `restart` but ABOVE the
            // `startPlayers(` call, and `loopContext = nil` is at :3185, INSIDE
            // `startPlayers`. The modular branch is intact here.
            let target = continuationAnchorInstant(startablePlayerCount: startable)
            // ⚠️ HOISTED INTO ITS OWN `let`, NOT INLINED INTO THE CALL — the
            // reason is "formatting is load-bearing", below, and it is a pin
            // constraint, not a style preference.
            let beats = resumeBeat(at: target, line: line)
            startPlayers(fromBeat: beats, tempoMap: tempoMap, renderClockTrusted: true, cause: cause,
                         anchorPolicy: .atHostTime(target))
        }
    }
```

⚠️ **FORMATTING IS LOAD-BEARING HERE, and this design settles it rather than leaving it to the
implementer — §8 Step 5's mistake repeated would cost a red whose obvious "fix" is to weaken a pin.**

- **`NoteChaseSiteTests.internalForwardsAreTransparent` matches PER LINE.** A forward is a line
  containing `cause: cause`, and it is credited to `startPlayers` only if THAT SAME LINE also contains
  `startPlayers(`. B-L10 (§14.8) asserts three forwards with **two** of them `startPlayers(` — true only
  if `cause: cause` ends the first line of BOTH calls.
- **An earlier draft of this section inlined `resumeBeat(at: target, line: line)` into the call**, which
  pushes `cause: cause` onto the continuation line and yields **one** `startPlayers(` forward, not two.
  **Hoist the beat into its own `let`.** Both `startPlayers(` lines are then BYTE-IDENTICAL, which is
  also the cheapest way to write B-L10: count identical lines rather than match two variants.
- **The reorder lever is CLOSED and the roadmap still records it as the plan.** m23-bs-2's roadmap text
  says "keep `cause: cause` on the `startPlayers(` line and move `renderClockTrusted` to the
  continuation line". Swift requires call arguments in DECLARATION order and `startPlayers` declares
  `renderClockTrusted:` (`AudioEngine.swift:3178`) before `cause:` (`:3179`), so that is **not
  expressible**; the in-source comment at `AudioEngine.swift:3119-3123` already records the finding.
  Do not re-attempt it, and do not reorder the declaration to make it possible — that would touch all
  six call sites and restate a comment bs-2 just landed, for a formatting win that is not needed
  anyway — as the next bullet measures.
- **Width, MEASURED, not guessed.** The hoisted `startPlayers(` line is **101 chars** at 12-space
  indent (the existing `restart` call at `AudioEngine.swift:3129` is the same text at 8-space indent:
  97). There is **no SwiftLint/lint config in this repo**, and `AudioEngine.swift` already carries
  lines of 104, 105, 108, 109 and 114 chars (`PlaybackGraph.swift` reaches 186). Width is NOT the
  binding constraint at this site; **per-line pin matching is**. If a future cycle adds a line-length
  rule, the lever is hoisting more arguments into `let`s — never moving `cause: cause` off its line.

**§5.1 confirmation, as the brief asked:** a derivation inside `restart` but above the `startPlayers(`
call is OUTSIDE the hazard. `startPlayers` clears `loopContext` at `:3185`; nothing in `restart`
touches it. Two guards keep it that way — the site pin asserts both the count read and the
`resumeBeat` call precede the `startPlayers(` line in `restart`, and leg B-L4 (§14.8) is the live
catch.

**Reading `mach_absolute_time()` AFTER `stopAllPlayers()` is load-bearing:** it measures the stop
instead of predicting it, so `scheduleAllowanceSeconds` keeps exactly its §13.4 meaning (segment B
only) at every site in the tree. This is the concrete thing the caller-side forwarded-parameter form
would have lost.

**Two `startPlayers(` calls, deliberately not collapsed.** A single call with a computed
`(beats, policy)` pair would make `restart` — the ONE site with two answers — the one site
`StartAnchorPolicySiteTests` cannot statically read, which is exactly where a source pin earns its
keep. The costs are named and accepted in §14.9.

**Caller rewrites.**

| line | caller | becomes | note |
|---|---|---|---|
| `:884` | `seek` | `.beat(transport.positionBeats)`, `.relocation` | unchanged behaviour |
| `:899` | `setTempo` | `.continuing(from: anchor.line)`, `.continuation` | see below |
| `:976` | `tracksDidChangeBody` edits | `.continuing(from: anchor.line)`, `.continuation` | THE most frequent site |
| `:2136` | `loopChanged` | `.continuing(from: anchor.line)`, `.continuation` | see below |
| `:3567` | loop-wrap fallback | `.beat(loopStartBeat)`, `.relocation` | unchanged, deliberately |

- **`setTempo` still needs `let beats = derivedBeats()`** — not for `restart`, but for
  `lastKnownBeats = beats` and `playheadHandler?(beats)` at `:900-901`, which must keep publishing the
  STOP-instant beat (§6's rule) and stay byte-identical. Two numbers, two jobs; say so in the comment,
  because deleting the now-"unused-looking" `derivedBeats()` is the obvious tidy-up. It also needs
  `guard let anchor = currentAnchor` in place of today's `!= nil`.
- **`setTempo`'s map question, answered so nobody re-derives it:** the resume beat is derived off the
  OLD map for the whole interval `[now, H]`, and that is CORRECT. Nothing renders under the new tempo
  before `H` — the players are stopped — so the new map governs from `H` exactly, which is when the
  new schedule sounds. The alternative (splice the new map in at `now`) would move the transport by
  `(H − now)·(β_new − β_old)` for no audible reason.
- **`loopChanged`'s wrap basis:** `cacheTransportFlags` has already updated `loopStartBeat`/
  `loopEndBeat`, but `loopContext` still describes the OLD window, so `resumeBeat` wraps against the
  schedule that is actually playing. Same basis `derivedBeats()` uses at that line today, evaluated
  later. No new hazard.

---

### 14.6 THE TRUSTED BRANCH RUNS FOR THE FIRST TIME — and δ eats part of the allowance

**Correction to the brief and to bs-2's own risk framing.** `recoverEngine` is the only `.atHostTime`
site today and it passes `renderClockTrusted: false`. The rewire and rebuild resumes also pass
`false`. **So `AudioEngine.swift:3281-3297` — the `.atHostTime` branch of the `anchorSample` switch —
has never executed in production, and bs-3a does not execute it either. `restart` passes
`renderClockTrusted: true`, so bs-3b is the FIRST item that runs it.** The brief's "source-pinned at
bs-2, live-proven here" is true of bs-3b alone. This is the strongest single argument for the split
(§14.10).

**And it carries a consequence bs-2 could not have measured.** In the trusted branch

```
earliest = renderTime.hostTime + leadHostTicks + countInHostTicks      // :3263
```

and `renderTime.hostTime ≈ mach_absolute_time() + δ` (§13.1 — the render callback holds a
PRESENTATION-domain stamp, δ ahead of now). The caller predicts `H = now + lead + allowance`.
Therefore

```
H − earliest  ≈  allowance − δ
```

**At the `restart` sites the effective allowance is `scheduleAllowanceSeconds − δ`, not 30 ms.** With
δ on this machine a sawtooth over `[b + L, 2b + L]` = `[12.0, 22.6] ms` (512 frames @ 48 kHz plus
1.3 ms presentation latency — the ARCHITECTURE entry's own correction), the remaining margin is
**~7–18 ms**, against bs-1's median segment B of 0.7 ms but its full-suite worst of 20.2 ms.
**Occasional overruns at `restart` sites under full-suite load are EXPECTED, not a defect** — they
clamp forward, are counted, are printed, and cost ≤ ~20 ms against today's unconditional ~75 ms. The
legs must be designed for that (§14.8: no leg asserts `overrunCount == 0` at a `restart` site).

**And it exposes a genuine imprecision in bs-2's clamp that bs-3b should fix.** The clamp asks *"can
the serial `play(at:)` loop finish before `target`?"* That loop begins at wall-clock now and costs
`lead`, so its true deadline basis is `mach_absolute_time() + lead`. Using the render clock's
presentation stamp as "now" over-estimates `earliest` by δ and clamps forward δ too eagerly. Fix,
scoped to `.atHostTime` only:

```swift
// The clamp threshold is a WALL-CLOCK question (when can the serial start loop
// finish?), so it uses the host clock in BOTH branches. `anchorSampledHost` is
// already read at :3253. ⚠️ `.asSoonAsPractical` keeps `renderTime.hostTime +
// lead` VERBATIM — it is the anchor, not a threshold, and "today byte-identical"
// is what makes the null case reviewable (§13.6).
let earliestForPolicy = anchorSampledHost + leadHostTicks + countInHostTicks
```

This LOWERS the threshold by δ, so it clamps LESS often — it removes conservatism rather than adding
risk, and it restores `scheduleAllowanceSeconds` to a uniform 30 ms at every site, which is what
§13.4's doc comment already claims. **It is the least-proven part of §14 (§14.12).** If the implementer
declines it, everything else stands and the only change is that `restart` overruns are commoner; say
which was done in the close-out.

**A second consequence, and it is a sharp falsifiable prediction for bs-3b's live leg.** Before and
after a `restart`, `hasSampleAnchor` is true on BOTH anchors, so the playhead reads the SAMPLE branch
on both sides. Unlike `recoverEngine` there is **no change of display basis and therefore no `β·δ`
residue** at a `restart` continuation. So a restart-continuation's lag should converge on the
no-restart control EXACTLY (modulo any overrun), with none of §13.9 #5's `+2·δ` correction. **If the
measured restart lag lands at `control + 2δ` instead of `control`, §13.1's model of δ is wrong and
that is worth stopping for.**

**Doc amendment (bs-3b):** `StartAnchorBudget.scheduleAllowanceSeconds` gains a third numbered clause
recording that the trusted-branch clamp basis is a wall-clock question and why, so a future author
does not "restore symmetry" and silently spend δ of the allowance again.

---

### 14.7 PER-SITE ANSWERS

| # | site | policy after bs-3 | where the INSTANT is chosen | where the COUNT is read | horizon | trusted? |
|---|---|---|---|---|---|---|
| 1 | `startPlayback` `:846` | `.asSoonAsPractical` | n/a — earliest | inside `startPlayers` (`:3237`) | n/a | `true` |
| 2 | `tracksDidChangeBody` rewire resume `:999` | **`.atHostTime`** (bs-3a) | at the resume site, immediately before `startPlayers` | **at QUIESCE** (`:623`, above the hook's `stopAllPlayers` at `:628`), carried | `lead(n_quiesce) + 0.030` | `false` |
| 3 | `rebuildEngine` resume `:1184` | **`.atHostTime`** (bs-3a) | at the resume site, immediately before `startPlayers` | **at QUIESCE** (`:1046`, above `:1050`), carried | `lead(n_quiesce) + 0.030` | `false` |
| 4 | `startTakeBody` `:2869` | `.asSoonAsPractical` | n/a | inside `startPlayers` | n/a | `true` |
| 5a | `restart` relocation branch | `.asSoonAsPractical` | n/a | read at `restart` entry (unused on this branch) | n/a | `true` |
| 5b | `restart` continuation branch | **`.atHostTime`** (bs-3b) | inside `restart`, after `stopAllPlayers`, above `startPlayers` | **at `restart` entry**, above `:3113` | `lead(n_entry) + 0.030` | `true` |
| 6 | `recoverEngine` `:3751` | `.atHostTime` (bs-2) | after segment A, before `startPlayers` | recovery entry, above `:3692` | `lead(n_entry) + 0.030` | `false` |

**The critical asymmetry to notice:** at sites 2 and 3 the count is captured at quiesce and an
arbitrary amount of work runs before the resume — but **the INSTANT is still chosen at the resume
site**, so all of that work is MEASURED, not predicted. §10 ranked the rebuild resume "the largest
instance"; under §1(a)'s late derivation it becomes **the same size prediction problem as every other
site**, because everything before the derivation point is eliminated exactly rather than estimated.
Only the COUNT is stale, and staleness there costs 8 ms per surprise against a 30 ms allowance, with
clamp-forward behind it. **That reframing is the reason bs-3a is a small item and not a hard one.**

---

### 14.8 VERIFICATION

Every leg names the mutation that reddens it. Legs are split by item.

#### bs-3a legs

| # | leg | device? | RED under |
|---|---|---|---|
| **A-L5′** | `StartAnchorPolicySiteTests` table rows 2 and 3 → `atHostTime`; `continuations == ["tracksDidChangeBody", "rebuildEngine", "recoverEngine"]` | **no** | flipping neither site, or only one |
| **A-L7** | **NEW headless pin: every `graph.startablePlayerCount` read precedes the next `stopAllPlayers()` in its enclosing method** | **no** | the §13.3 landmine at ANY of the four sites — including the two with no live leg |
| **A-L8** | **NEW headless pin: the resume state carries NO beat.** `resumeAfterRoutingRewire`'s declaration matches `line: AnchorLine` and contains no `beats:` label; `resumeBeat` is declared `at:line:` and there is exactly one such declaration | **no** | reintroducing the frozen beat, i.e. the §14.2 "derive forward from quiesce" option |
| **A-L9** | **NEW headless pin: `loopContext` is assigned in exactly three places** (`windDownAfterException`, `stopPlayback`, `startPlayers`) | **no** | a fourth writer, which would break §14.2's pairing assumption silently |
| **A-L1′** | **The rebuild-site property witness — ZERO new live sessions.** Extend the existing `EngineRebuildTests.midPlayStripBirthRebuildsAndResumes` (`Tests/DAWEngineTests/EngineRebuildTests.swift:424`, already `.serialized`, already rolls live playback): read `anchorLineForTesting` before the `tracksDidChange` that triggers the rebuild and after it; assert L1's closed form `abs(b1 − (b0 + β·Δt)) <= ε`, `continuationStartCountForTesting` +1, L2's unconditional `<= reportedOverrunBeats + ε`, and L3's `lastContinuationPlayerCountForTesting == nSnapshot` | **yes (existing)** | leaving site 3 on `.asSoonAsPractical` (L1 half); reading the count at the resume site — engine reports **0** vs snapshot `n` (L3 half) |

⚠️ **A-L7's rule, stated so it cannot be mis-implemented — "no `stopAllPlayers()` at all" is a
PASS.** For each `graph.startablePlayerCount` read, inside the enclosing declaration's line range:
a `stopAllPlayers()` occurring AFTER the read → **PASS**; a `stopAllPlayers()` occurring BEFORE the
read with none after → **FAIL**; **no `stopAllPlayers()` in the declaration at all → PASS**. The last
clause is not a loophole — `startPlayers`' own read at `AudioEngine.swift:3237` has no
`stopAllPlayers()` in its body and is correct, and a pin that failed it would be deleted within a
cycle. The four reads the rule exists FOR are `recoverEngine`, the quiesce hook, `rebuildEngine`'s
quiesce, and (at bs-3b) `restart`. ⚠️ **Scope by the enclosing 4-space-indented `func` declaration,
not by brace depth**, and CONFIRM which declaration lexically contains the quiesce hook at
`AudioEngine.swift:621-632` before writing the slice — it is a closure, so its enclosing declaration
is whatever `func` assigns it, and a slicer that guesses wrong will silently cover three sites while
reporting four. Record the confirmed range in the test's header.

⚠️ **A-L1′ needs a FIXTURE CHANGE and it is not optional.** That test's project is one `.testTone`
INSTRUMENT track plus an empty audio track. `startablePlayerCount` walks `trackNodes` (audio clip
nodes) while instrument tracks live in `instrumentNodes`, so `nSnapshot == 0` and the L3 half would be
**vacuous** — bs-2's own L3 anti-vacuity rule, in the same trap bs-1's header names. **Give the fixture
one AUDIO clip** (`TestSignals.fixtures()`, bs-1's "beats 4…28" future-clip convention) and assert
`nSnapshot >= 1` with its reason. The implementer must re-run the test's ORIGINAL assertions after the
fixture change and confirm the strip-birth announce still fires — that announce is what the test
exists for.

**The rewire resume (`:999`) gets a source pin and NOTHING ELSE, and this design says so plainly
rather than implying coverage.** It is **unreachable in this tree**, derived rather than asserted:
the hook's body no-ops unless `engine.isRunning` (`:622`); `isRunning`/`graph.engineHasRun` are set
together at both start sites (`:750`/`:756`, `:1153`/`:1154`) with nothing between that can reconcile,
so `engine.isRunning ⟹ graph.engineHasRun`; every announce site sets `needsEngineRebuild = true` when
`engineHasRun` (`PlaybackGraph.swift:699`, `:2148`); and `tracksDidChangeBody` aborts into
`rebuildEngine` at `:954`, which consumes the resume state, before reaching `:978`.
**Flip it anyway.** The no-default discipline exists so that a future reachable path inherits a
*stated* answer; leaving one continuation on `.asSoonAsPractical` leaves a site whose recorded answer
is known-wrong, which is the m23-bq shape one level up. It gets policy-flipped, count-at-quiesce'd,
and covered by A-L5′/A-L7/A-L8 — no live leg, and the close-out must say so in one sentence.

**bs-3a mutants (run filtered, record the numbers in the changed files' headers):**
(a) leave sites 2+3 on `.asSoonAsPractical` → **A-L1′ RED, A-L5′ RED**. ⚠️ **Measure the margin, do
not predict it** — that fixture's rebuild duration is unknown to this design, so the mutant's beat
magnitude is unknown; record it.
(b) read the count at the resume site → **A-L1′'s L3 half RED (0 vs n), A-L7 RED, the L1 half GREEN**
(a budget error is not a derivation error — that split is why both exist).
(c) horizon ≡ 0 → **L3 half RED, L1 half SKIPS loudly**, proving the skip is bounded.
(d) carry `(beats, quiesceHost)` and derive forward (the §14.2 rejected option) → **A-L8 RED**.
⚠️ **Nothing else catches (d): in a LINEAR fixture it is algebraically close enough to pass A-L1′.**
Its real defect is the modular-origin error, and bs-3a has no loop leg. **That is a named coverage
gap, closed structurally by A-L8 rather than behaviourally.** Do not delete A-L8 as "just a source
pin".
(e) unconditional clamp (no forward clamp) → **nothing reddens**, by design — the past-anchor case is
prevented by construction, not by test (§13.7 (d)).

**No new loop leg for bs-3a.** bs-2's L4 (`recoveryUnderALoopWrapsModularly`) already covers the only
mistake that class of leg can catch — a derivation moved INSIDE `startPlayers`, past `loopContext =
nil` — and there is exactly one `startPlayers`, so one L4 covers every caller.

#### bs-3b legs

| # | leg | device? | RED under |
|---|---|---|---|
| **B-L5″** | `StartAnchorPolicySiteTests` grows to **seven** rows, `restart` twice (`asSoonAsPractical` then `atHostTime`, in file order); `continuations == ["tracksDidChangeBody","rebuildEngine","restart","recoverEngine"]`; plus source assertions that (i) `restart`'s count read and `resumeBeat` call both precede its `startPlayers(` lines, (ii) the `.atHostTime` clamp threshold in the trusted branch derives from `anchorSampledHost`, not `renderTime.hostTime` (§14.6) | **no** | collapsing the two calls into one computed policy; moving the derivation below the call; restoring the render-clock clamp basis |
| **B-L6** | `RenderClockTrustSiteTests` grows to **seven** rows, `restart` twice, **both `true`**; the `untrusted` SET is unchanged | **no** | a `restart` branch that stops trusting the render clock (it does not bounce the engine) |
| **B-L10** | `NoteChaseSiteTests.internalForwardsAreTransparent`: `forwards.count` 2 → **3**, with **two** containing `startPlayers(` and one `graph.scheduleAll(` | **no** | a `restart` branch that names a literal cause instead of forwarding |
| **B-L1** | **The restart property witness — ONE new live session**, a new `@Test` in the `extension RecoveryPlayheadTests` (`RecoveryAnchorContinuityGateTests.swift`): roll with ≥1 audio clip, loop OFF, read `anchorLineForTesting`, apply an edit through `tracksDidChange` (the m23-bp trigger — a clip move or a note edit flips `changed`), read again; assert L1's closed form, `continuationStartCountForTesting` +1, L2 unconditionally, L3 against the test's own pre-edit snapshot | **yes (+1)** | leaving `restart` on `.asSoonAsPractical` (≈ lead+B+δ ≈ 0.075 s ≈ **0.15 beats** against ε 1e-12); deriving the beat at the caller and forwarding `.atHostTime` (≈ the horizon, ~0.09 s ≈ 0.18 beats) |
| **B-L4** | **The restart loop-wrap witness — ZERO new sessions**: fold an edit-while-rolling step into bs-2's existing `recoveryUnderALoopWrapsModularly` session, BEFORE its bounce, attributed by `continuationStartCountForTesting` | **yes (existing)** | a linear derivation at the `restart` site under an active loop |

⚠️ **B-L1 must NOT assert `overrunCount == 0`.** §14.6: the trusted branch's effective allowance is
`30 ms − δ` ≈ 7–18 ms here, so occasional overruns under full-suite load are expected machine facts.
It follows bs-2's L1 exactly — **skip and report LOUDLY** on overrun, with L2 (never skipped) and L3
(a pure read-back) closing the hole. PRINT the overrun count and worst magnitude on every run; a
persistent non-zero count is the signal to reconsider §14.6's clamp-basis fix, never to loosen L1.

⚠️ **B-L4's FOLD IS A PROBE INTO THE TREE'S ONLY §5.1 GUARD — run the leg UNCHANGED first.**
`recoveryUnderALoopWrapsModularly` (`Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift:610`)
is, by §13.7's own words, the ONLY automated catch for a derivation moved INSIDE `startPlayers`.
Inserting a `restart` before its bounce changes which anchor the recovery reads and adds a wrap the
leg did not have. **Procedure, in this order: (1) run the leg unchanged and RECORD its measured
numbers; (2) add the `restart` step; (3) re-run and compare. If any of its own pre-existing assertions
or measured margins move, give B-L4 its OWN session instead of folding.** A +1 session (total
≈ 7–9, still below the pre-bs-2 ≈ 9–10) is cheaper than a perturbed L4 — and the failure mode of
getting this wrong is not a red, it is **an L4 that still passes while covering less**, which is the
one outcome this whole design is built to avoid.

**bs-3b mutants:** (a) revert `restart` to `.asSoonAsPractical` → **B-L1 RED (~0.15 beats)**;
(b) collapse the two `startPlayers` calls → **B-L5″ RED**; (c) read the count below `restart`'s
`stopAllPlayers()` → **A-L7 RED and B-L1's L3 half RED**; (d) derive the beat at the caller and forward
`.atHostTime` → **B-L1 RED by ≈ the horizon**; (e) linear derivation under a loop → **B-L4 RED**;
(f) restore the render-clock clamp basis → **B-L5″ RED** (the overrun-rate consequence is a magnitude,
not an assertion — it is printed).

#### Session budget (§13.8's rule, inherited unchanged)

- Post-bs-2 default full run: **≈ 5–7** live playback sessions.
- **bs-3a: +0.** A-L1′ rides `EngineRebuildTests:424`, which already runs one; A-L5′/A-L7/A-L8/A-L9
  are headless source pins.
- **bs-3b: +1** (B-L1). B-L4 folds into bs-2's existing L4 session.
- **Total after bs-3: ≈ 6–8** — still strictly below the pre-bs-2 baseline of ≈ 9–10, with the
  arithmetic shown so a reviewer can check it rather than believe it.
- ⚠️ **The implementer MUST measure this by running, not by trusting this table.** If the measured
  count comes out higher, the named remedy is folding B-L1 into bs-2's L1 session (one session, two
  events, each attributable via `continuationStartCountForTesting`) — accepting that a conflated
  session makes a failure harder to attribute — **not proceeding**.

#### The `n >= 6` coverage gap — closed as an OBSERVATION, not a new assertion

Every bs-2 live green ran in the lead-floor regime (`n = 0` at L1, `n = 1` at L3); below `n = 6` the
lead is pinned at 0.06 and the `0.008·n` term has never been seen doing work live. **But §13.7 already
decomposed this deliberately**: L0 owns the formula (headless, exact, at every n), L3's horizon
identity is an exact read-back at ANY n, and the count-source mutant reddens at `n = 1`. So what is
missing is an **observation that the scaling term ran live**, not an assertion — and §13.8 has already
committed not to add a live session for one.

**Decision: print it from the fixture that already has it.** `RecoveryCostSplitTests`' realistic
project (8 tracks / 32 clips / **16 audio players**) is the only ≥6-player live fixture in the tree and
is already env-gated behind `DAWPRO_M23BS_COSTSPLIT=1` with a visible skip line (§13.8). Add one
printed line — `[measured] m23-bs-3 n=… lead=… horizon=… overruns=…` — to its realistic sweep, run it
once with the env var set, and **record the numbers in the bs-3a close-out record.** Zero
default-run sessions, zero new fixtures, and the observation is dated and attributable.
**Say plainly in the close-out that this is an observation and not a regression guard**; the guards
remain L0 and L3.

#### Regression surface

`StartAnchorPolicySiteTests`, `RenderClockTrustSiteTests`, `NoteChaseSiteTests`,
`RecoveryAnchorContinuityGateTests`, `RecoveryPlayheadTests`, `EngineRebuildTests`,
`EngineWatchdogTests`, `RecoveryOutputPinGateTests`, `GaplessLoopTransportTests` (the known
contention flake — do NOT lower its `>= 1` bar; m23-bu-2 owns it), `GaplessLoopEditFallbackTests`,
`GaplessLoopMetronomeTests`, `MetronomeMeterMapTests`, `LoopRecordEngineTests`, plus a full
`./scripts/test.sh` **backgrounded (~90 s) with `grep '^✘'` — the script EXITS 0 on a failed run.**
Baseline to hold: **4515 tests / 466 suites, zero `✘`**.

---

### 14.9 THE TWO PINS — what moves, when, and to what

The brief says both pins move together. **They do not, and getting this wrong costs a confusing red.**

| pin | bs-3a | bs-3b |
|---|---|---|
| `StartAnchorPolicySiteTests` | rows 2, 3 → `atHostTime`; `continuations` set becomes `["tracksDidChangeBody","rebuildEngine","recoverEngine"]`; header table rewritten (the "KNOWN-WRONG-BY-DESIGN" note at `:66-69` is DELETED — it has been discharged) | six rows → **seven**; `restart` appears TWICE; `continuations` gains `"restart"`; two new source assertions (§14.8 B-L5″) |
| `RenderClockTrustSiteTests` | **UNCHANGED.** Flipping the anchor policy does not change the trust answer — the engine still bounced, both sites stay `false`, and the `untrusted` set is identical | six rows → **seven**, `restart` twice, **both `true`**; `untrusted` set **unchanged**. A ROW-COUNT change, not an answer change |
| `NoteChaseSiteTests` | unchanged | `internalForwardsAreTransparent`: 2 forwards → **3**, two of them `startPlayers(`. `causeSequenceMatchesDesignTable` is UNCHANGED — it matches `cause: .relocation`/`.continuation` literals and both `restart` branches say `cause: cause` |

**Both movements are deliberate acts.** A bs-3a that updates only the policy pin is CORRECT (the trust
pin genuinely does not move); a bs-3b that updates the policy pin without the trust pin will red on
the row count. Neither is an obstacle to route around.

---

### 14.10 SPLIT — bs-3 is TWO items, and the order matters

**Yes, split. bs-3a (rewire + rebuild resumes) lands first; bs-3b (`restart`) lands alone after it.**
The roadmap entry `m23-bs-3` should be re-labelled as the parent and split in place.

**bs-3a — the shared mechanism, on the branch bs-2 already proved.**
`AnchorLine`, `PlaybackAnchor.line`, `resumeBeat(at:line:)`, the carried
`(line, startablePlayerCount)` resume state, `continuationAnchorInstant` + the per-event counter,
`lastKnownBeats` at quiesce, both resume sites flipped, four headless pins and one extended live test.
It touches the UNTRUSTED anchor branch only — the branch bs-2 exercised live end-to-end — so nothing
in it runs code that has never run.

**bs-3b — the frequent path, alone.** `RestartOrigin`, five caller rewrites, the count read above
`restart`'s own `stopAllPlayers`, the §14.6 clamp-basis fix, three site pins moved, one new live
session. It is the item that (i) executes the trusted `.atHostTime` `anchorSample` derivation for the
first time in production, (ii) changes behaviour on **every note edit and clip move while rolling**,
and (iii) touches a third site pin. Landing it alone keeps a bisect unambiguous: if a loop, metronome,
recording or gapless test moves, exactly one commit can be responsible.

**Why this order and not the reverse.** bs-3b CONSUMES bs-3a's `AnchorLine`, `resumeBeat(at:line:)`
and `continuationAnchorInstant`. Doing `restart` first would either duplicate them or force the same
refactor with a larger blast radius attached.

⚠️ **`bs-3a`/`bs-3b` DO NOT EXIST AS ROADMAP IDS YET, and this document's own header forbids citing
ids that do not.** `docs/ROADMAP.md` is authoritative; §14 cites `bs-3a`/`bs-3b` throughout on the
strength of this recommendation alone. **The split must land in `docs/ROADMAP.md` — `m23-bs-3`
re-labelled as the parent with two lettered children — BEFORE an implementing agent is briefed with
these ids.** Until then they are proposals, not references, and an agent told to "do bs-3a" will find
nothing.

⚠️ **THE SITE NAMES DIFFER BETWEEN THE ROADMAP AND §8, AND NOTHING WAS DROPPED.** The roadmap's
`m23-bs-3` text names the three sites as **`rebuildEngine` resume, `restart` (via
`tracksDidChangeBody`), and `setTempo`**; §8's table names them as **rewire resume, rebuild resume,
`restart`**. §14 covers the UNION of both lists: `setTempo` (`AudioEngine.swift:899`) is not a separate
mechanism — it is a `restart` CALLER, handled by §14.5's caller table along with `loopChanged`, the
edit path and the loop-wrap fallback, and it is the one caller with a live subtlety of its own (the
old-map derivation, §14.5). The rewire resume (`:999`) is the fourth site, absent from the roadmap
text, and §14.8 states plainly that it is unreachable in this tree and gets a source pin only.
⚠️ **The roadmap entry's line numbers are PRE-bs-2 and STALE** (`:944`, `:1124`, `:928`, `:851`,
`:3036`, `:3042`, `:3088`); §14's are post-bs-2. Re-verify by symbol, never by line, and refresh the
roadmap's numbers when the split lands.

**Optional third cleave, if bs-3b gets long:** the §14.6 clamp-basis fix (`earliestForPolicy` from
`anchorSampledHost`) can be deferred to its own item. It is the least-proven piece and the only one
that edits code bs-2 shipped. Deferring it costs a commoner overrun rate at `restart` sites and
nothing else. **Do not defer it silently** — if deferred, B-L1's header must record the expected
overrun rate and why.

---

### 14.11 Corrections to the brief and to §1–§13 — named here, not edited there

1. **§8's site table row 5 ("bs-3 makes this a forwarded parameter") is superseded.** `restart` takes a
   `RestartOrigin`, not a forwarded `anchorPolicy`; §14.5 argues why both of the brief's options lose.
2. **The brief's "the sites bs-3 flips are precisely the ones carrying `renderClockTrusted: false`, so
   both pins move" is half right.** The two `false` sites are indeed the ones bs-3a flips, but flipping
   the POLICY does not change the TRUST answer, so `RenderClockTrustSiteTests` does not move in bs-3a
   at all. It moves in bs-3b, by a row count, at a site that is `true` (§14.9).
3. **§10's ranking of `rebuildEngine` as "the LARGEST instance" is true of the DEFECT and misleading
   about the FIX.** Under §1(a)'s late derivation, everything between quiesce and the resume is
   measured rather than predicted, so the rebuild's unbounded duration is eliminated exactly. What is
   actually stale at that site is only the player COUNT (§14.3, §14.7).
4. **The brief's "`.atHostTime` at those sites would anchor a STALE beat at a NEW instant" is exactly
   right and is the reason the resume STATE, not the policy, is bs-3's real subject.** Recorded because
   it is the trap a reader who skims the site table will fall into.
5. **§13.7's L5 row and §11's risk register both under-state the trusted branch's status:** its
   `.atHostTime` `anchorSample` derivation is DEAD CODE as shipped, and bs-3b is its first execution
   (§14.6). "Source-pinned at bs-2, live-proven at bs-3" is true only of bs-3b.
6. **`StartAnchorBudget.scheduleAllowanceSeconds`' doc comment is incomplete for the trusted branch.**
   Its 30 ms is spent down to `30 − δ` there (§14.6); bs-3b adds the third numbered clause.
7. **The bs-1 preamble's §4 block-quote already named the rewire resume as "the one continuation site
   where the project DID change" and deferred it to bs-3.** §14.3 accepts the exposure and bounds it
   with the monotonicity argument (an overrun IS today's behaviour), rather than trying to remove it.
8. **§9.1's "one caller today, and the place every bs-3 site must come to" is now literally true** —
   four callers, one derivation, via the narrowed `resumeBeat(at:line:)`.

---

### 14.12 What I am NOT confident about

- **The §14.6 clamp-basis fix.** The argument (the serial start loop's deadline is a wall-clock
  question, so the threshold belongs in the host domain) is sound to me, but it edits a clamp bs-2
  shipped, on a code path nobody has run, and I have not measured δ's effect on the overrun rate. It
  is scoped to `.atHostTime` so it cannot perturb any existing behaviour — but "cannot" is an argument,
  not a measurement.
- **A-L1′'s mutant margin.** I do not know how long that fixture's rebuild takes, so I cannot predict
  the beat magnitude the entry-derivation mutant produces there. It is certainly enormous against
  ε = 1e-12, but the number must be MEASURED and recorded, not asserted from this document.
- **Whether adding an audio clip to `EngineRebuildTests:424`'s fixture preserves what that test is
  for.** The strip-birth announce is its subject; a differently-shaped project could plausibly change
  which reconcile step announces first. Re-run its original assertions before trusting the extension.
- **Whether a rebuild MID-TAKE is reachable, and what it does today.** Neither the hook nor
  `rebuildEngine` consults `activeTake`. If it is reachable, §14.1's recording argument becomes a
  correctness argument; if it is already broken, it is evidence for nothing. **Unverified — file it,
  do not cite it.**
- **The overrun rate at `restart` sites under full-suite load.** Predicted "occasional, magnitude
  ≤ ~20 ms" from bs-1's B distribution and this machine's δ sawtooth. One machine, one buffer size, one
  thermal state.
- **The pairing of the carried line with the surviving `loopContext`.** I verified the three
  `loopContext` writers and that every quiesce→resume path is one synchronous main-actor stretch, but
  the guard I propose is a debug assertion, not a proof, and an async resume would break it silently.
- **The session-count arithmetic in §14.8.** Stated with its derivation so it can be checked; it has
  not been measured on this tree.
- **Whether `n_quiesce` is ever wildly wrong at the rebuild site.** The store stops the transport before
  a project boundary (verified), which removes the only caller that could swing it hard — but that is
  the store's discipline, not the engine's invariant, and I did not audit every `tracksDidChange`
  producer.

---

### 14.13 IMPLEMENTATION ORDER

**bs-3a** (`Sources/DAWEngine/AudioEngine.swift` throughout; no other production file changes)

1. `AnchorLine` next to `PlaybackAnchor` (`:157`), plus `PlaybackAnchor.line`. Narrow `resumeBeat` to
   `(at:line:)` (`:3627`) and update `recoverEngine`'s call (`:3750`) to `anchor.line`. **Build green
   before anything else changes** — this step is behaviour-neutral by construction.
2. `continuationAnchorInstant(startablePlayerCount:)` (§14.4) + `continuationStartCountForTesting`.
   Move `recoverEngine`'s `:3744-3749` onto it. **Null-case check: `RecoveryAnchorContinuityGateTests`
   fully green, residue still 0.000e+00, before touching any new site.**
3. `resumeAfterRoutingRewire` → `(line: AnchorLine, startablePlayerCount: Int)?` (`:493`). Both quiesce
   sites (`:623-625`, `:1046-1047`): read `graph.startablePlayerCount` **above** the `stopAllPlayers()`,
   set `lastKnownBeats = derivedBeats()`, store the line + count.
4. Both resume sites (`:999`, `:1184`): `continuationAnchorInstant` → `resumeBeat(at:line:)` →
   `.atHostTime`. Keep `renderClockTrusted: false`. Add the debug `currentAnchor == nil` assertion.
5. Headless pins: A-L7, A-L8, A-L9 (new file
   `Tests/DAWEngineTests/ContinuationResumeStateSiteTests.swift`, mirroring
   `StartAnchorPolicySiteTests`' source-access idiom verbatim); A-L5′ (edit the existing table AND its
   header prose — delete the discharged "KNOWN-WRONG-BY-DESIGN" note).
6. `EngineRebuildTests:424`: audio-clip fixture, anchor-line reads, the four assertions (A-L1′). Verify
   the ORIGINAL assertions still pass.
7. Mutants (a)–(e) filtered; record every number in the changed files' headers.
8. One env-gated `DAWPRO_M23BS_COSTSPLIT=1 ./scripts/test.sh --filter RecoveryCostSplit` run for the
   `n >= 6` observation; record `n`, `lead`, `horizon`, overruns in the close-out.
9. Full backgrounded suite, `grep '^✘'`; measure the live-session count.

**bs-3b**

1. `RestartOrigin` + the new `restart` signature and body (§14.5), count read above `:3113`.
2. Five caller rewrites (§14.5's table), including `setTempo`'s two-numbers-two-jobs comment.
3. §14.6's `earliestForPolicy` in the trusted branch, `.atHostTime` only, with its comment; the
   `scheduleAllowanceSeconds` doc clause.
4. B-L5″, B-L6, B-L10 (three site pins).
5. B-L1 (new live `@Test` in the `RecoveryPlayheadTests` extension); B-L4 folded into
   `recoveryUnderALoopWrapsModularly`.
6. Mutants (a)–(f) filtered, recorded.
7. Full backgrounded suite, `grep '^✘'`; re-measure the session count against §14.8's arithmetic.

**Close-out (each item):** tick the roadmap, ORCH record with the measured mutant margins, CHANGELOG,
memory patch with re-measured baselines. Add **`AudioEngine.AnchorLine`** (the host-domain projection
— the one thing a continuation may carry across an engine bounce) and **`AudioEngine.RestartOrigin`**
(bs-3b) to the ONE-home registry. `docs/ARCHITECTURE.md` gains the transport-continuity entry
(already added by this design pass, marked SETTLED-not-yet-shipped — flip it to SHIPPED at bs-3b's
close and name the shipped sites).
