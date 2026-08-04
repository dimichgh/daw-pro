# m23-as-2 — the prepare-latency estimator for `AUPrepareRenegotiationStressTests`

**Status:** design, adjudicated. Written 2026-08-03 by `daw-architect` at the
start of m23-as-2, against sites #3/#4 of the m23-as canonical list.

**Scope:** `Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift:229-230`
only. §9 states the transferable law for the other four sites but does **not**
adjudicate them.

**Full Xcode requirement: NONE.** Nothing here touches entitlements, AUv3
hosting, code signing, or bundling. Everything below runs under Command Line
Tools via `./scripts/test.sh`.

---

## 0. Decision

| line | verdict |
|---|---|
| `#expect(minSeconds < 1.0)` (`:229`) | **KEEP, value unchanged.** Re-document it as *the* detector. Give it the mutation discriminator m23-as-2 requires. |
| `#expect(median < 8.0)` (`:230`) | **DELETE the assertion. KEEP the median in the `[measured]` print.** |
| the m23-as-2 prescription "convert to a same-run calibrated ratio" | **REJECTED for this site.** The item text must be corrected — §10 gives exact wording. |
| a `max` or `p90` bound | **MUST NOT BE ADDED.** Reaffirmed; §3's table is the evidence. |
| an added `withinCleanPathBudget >= m` count assertion | **MEASUREMENT-GATED, OPTIONAL.** §6.3. Its terminal state ("no defensible `m` exists → ship the deletion alone") is pre-authorised here so the implementer is not forced to invent one. |

The one-sentence justification: **AU prepare wall time in this suite is
~99.98 % scheduling queue wait, so every multiplicative instrument is inverted
here, and the median — the channel the test asserts on — is measurably the
noisiest of its four channels while retaining the least margin.** `min` is the
robust channel and the stronger detector for the regression class that
matters; the median assertion is a lossy soft proxy for a hard bound this test
already asserts exactly (a prepare that breaches the applicable timeout flips
`.failed` and the `.ready` expectations at `:141` and `:182` redden).

---

## 1. Adjudication of the additive-vs-multiplicative argument

**The argument is correct. Endorsed.** Evidence, all MEASURED (§3):

- Isolated median prepare: **0.000780 s**. Loaded median: **2.45–4.64 s**.
  Inflation **3 143×–5 945×**.
- Isolated min: **0.000168 s**. Loaded min: **0.052–0.079 s**. Inflation
  **312×–473×**.

A fully CPU-saturated machine produces a 2–10× slowdown. Nothing in the range
2–10 explains 473×, let alone 5 945×. This is queueing, not CPU contention.
That single arithmetic fact is decisive and does not depend on resolving
*which* queue.

### 1.1 Which queue — and why the answer does not change the verdict

Both candidate waits are additive, so the conclusion is robust either way.
Reading `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift`, one
`prepare(track:sampleRate:)` traverses these suspension points, every one of
which is a *wait for a serialized resource*, not a unit of work:

1. `prepare` builds `Task { @MainActor … }` and `await`s it — a main-actor
   enqueue behind the whole cooperative backlog (`:363-368`).
2. That task `await`s the previous prepare in the per-track chain
   (`prepareChains`) — serialization, though in this suite each prepare gets a
   fresh registry so the chain is depth-1.
3. `DeadlineRace.run` posts a second `Task { @MainActor in … }`
   (`Sources/DAWCore/DeadlineRace.swift:75`) — a second main-actor enqueue.
4. `.soundBank` is DLS-family, so `allocateRenderResourcesOnDLSQueue`
   (`:820-829`) hops to `dlsBankQueue` and back: one `dlsBankQueue` wait plus
   one main-actor re-acquisition on the continuation resume.
5. `loadSoundBank` (`:863-889`) does the same again: a second `dlsBankQueue`
   wait plus a third main-actor re-acquisition.

`dlsBankQueue` is a **single process-global serial queue**
(`AUHostRegistry.swift:85-86`). This test deliberately puts 8 prepares per
iteration plus renegotiation `dlsBankQueue.sync` hops plus teardown disposals
onto it concurrently. So the self-inflicted component is queue-position ×
critical-section length — additive. The ambient component is main-actor
backlog behind the ~78 % `@MainActor`-isolated sibling suites characterised at
m23-ab-3 — also additive.

**Neither is CPU slowdown. Neither is multiplicative.** The corollary to the
m23-as-1 law is exactly as the task states it:

> **A RATIO cancels MULTIPLICATIVE noise, not ADDITIVE noise** — the mirror of
> "subtraction cancels ADDITIVE noise, not MULTIPLICATIVE".

### 1.2 The killer number for the prescribed shape

Using `EQCurveEditorModelTests`' own MEASURED calibration denominator
(`calibrationWork(30_000)`: ~0.0007 s typical, up to 0.0016 s under
adversarial load — `EQCurveEditorModelTests.swift:776-807`):

| condition | prepare median | calibration | **ratio** |
|---|---|---|---|
| isolated | 0.00078 | ~0.0007 | **≈ 1.1** |
| full suite (best of 5) | 2.4517 | ~0.0007–0.0015 | **≈ 1 630–3 500** |
| full suite (worst of 5) | 4.6372 | ~0.0007–0.0015 | **≈ 3 090–6 620** |

The healthy ratio spans **three orders of magnitude**. Any `K` that passes the
loaded case is blind by a factor of ~3 000 in isolation; any `K` tight enough
to mean something in isolation reddens on every full-suite run. There is no
`K`. The m23-ab-2 shape is correct where it lives — `EQCurveEditorModel`'s
contaminant genuinely *is* CPU slowdown, and its measured healthy ratio spans
only [0.494, 1.192] across isolated / full-suite / adversarial conditions —
and it is inverted here.

---

## 2. Two findings the measurement forced that are not in the task brief

### 2.1 The bound's stated derivation rule is no longer satisfiable

`AUPrepareRenegotiationStressTests.swift:227-228` derives the constant as:

> `8 s ≈ 4× the worst measured median, still under the 10 s timeout horizon
> this test exists to keep far away.`

Two clauses, two different fates:

- **"≈ 4× the worst measured median" — NOT VOID, ERODED.** Worst median at
  calibration (2026-07-16) was 2.02 s. Worst of five runs today is
  **4.637 s**. The effective multiple is **1.73×**, not 4×. (The task brief
  said 2.5×, derived from a worst of 3.15 s; two further green full-suite runs
  taken for this design moved the worst to 4.637 s — see §3.)
- **"still under the 10 s timeout horizon" — VOID.** `timedPrepare` passes no
  `timeout:`, so the prepare gets `AUHostRegistry.defaultPrepareTimeout`, which
  is `testPrepareTimeout` = **60 s** in any process
  `TestEnvironment.isSwiftTestProcess` recognises — and `./scripts/test.sh`
  runs `swift test --disable-xctest`, whose harness binary is
  `swiftpm-testing-helper`, the first of the three recognised shapes. The
  horizon in the process where this assertion executes has been 60 s since
  m23-at. The clause has been factually wrong for as long as m23-at has been in
  the tree.

Now re-apply the rule to today's data. `4 × 4.637 = **18.55 s**`. The measured
`max/median` ratio across five runs is **4.44–10.15**, so the median at which
the *worst* prepare in a run reaches the 60 s horizon and flips `.failed` is
**60/10.15 = 5.9 s to 60/4.44 = 13.5 s**.

> **The rule's own output (18.55 s) exceeds even the most generous estimate of
> the median at which prepares begin to FAIL (13.5 s).** There is no longer any
> number that is simultaneously "4× the worst measured median" and "below the
> failure horizon". The rule that produced 8.0 has stopped having a solution.

That is the single strongest argument in this document, and it is arithmetic
on measured values, not judgement. A bound whose derivation rule is
unsatisfiable cannot be re-derived; it can only be deleted or replaced by a
different rule. §6 shows no better rule is available at acceptable cost.

### 2.2 The bound fires at or after the failure it would warn about

The current constant 8.0 sits **inside** the 5.9–13.5 s failure-onset band.
Depending on a given run's tail shape, `median < 8.0` reddens either
simultaneously with, or after, the first prepare timing out — and a timed-out
prepare already reddens `#expect(… == .ready)` at `:141`/`:182` with a far more
readable message. The median bound is therefore not an early warning. It is a
lossy restatement of a hard bound the test already asserts exactly.

The assumption's failure direction favours the conclusion: if the tail fattens
faster than the median as the harness grows, failures begin at a *lower*
median, making 8.0 later still.

### 2.3 One flag, not a new proposal

MEASURED: the worst prepare observed is **24.886 s, already 41 % of the 60 s
test horizon.** That is the number that will actually break this suite as the
harness grows, and it is evidence for the **open** item **m23-aw**. Do **not**
respond by raising `testPrepareTimeout` — m23-at's roadmap line forbids it, and
60 s was itself derived as ~2.2× a measured 26.9 s worst case, which today's
24.886 s is consistent with.

---

## 3. The measurements

All five loaded rows are `[measured] m19-e contended prepares` lines, n=32
each, on this tree, 2026-08-03. Runs **A/B/C** are the task brief's; runs
**D/E** were taken for this design (`./scripts/test.sh`, backgrounded,
sequential, ~90 s each). **D and E were both verified green before use:**
`Test run with 4692 tests in 483 suites passed`, `grep -c '✘'` = 0 on each.
Port 8001 verified free afterward (standing ACE hygiene rule).

| run | min (s) | **median (s)** | p90 (s) | max (s) | max/median | p90/median |
|---|---|---|---|---|---|---|
| isolated (`--filter`) | 0.000168 | **0.000780** | — | 0.0511 | — | — |
| full suite A | 0.065457 | **3.149543** | 14.143 | 23.206 | 7.37 | 4.49 |
| full suite B | 0.061028 | **2.466742** | 12.293 | 18.452 | 7.48 | 4.98 |
| full suite C | 0.062611 | **2.451709** | 11.041 | 24.886 | 10.15 | 4.50 |
| **full suite D (new)** | 0.052400 | **4.637244** | 11.059 | 20.574 | 4.44 | 2.38 |
| **full suite E (new)** | 0.079429 | **2.486943** | 12.049 | 18.879 | 7.59 | 4.85 |

### 3.1 Derived, MEASURED

**Run-to-run spread of each channel (worst observed / best observed, 5 loaded
runs):**

| channel | spread | headroom left against its bound |
|---|---|---|
| min | **1.52×** | 1.0 / 0.0794 = **12.6×** |
| **median** | **1.89×** | 8.0 / 4.6372 = **1.73×** |
| p90 | 1.28× | unasserted |
| max | 1.35× | unasserted |

> **The channel this test asserts on is, in relative terms, its NOISIEST
> channel — and the one with the least margin.** Both facts point the same way.

**The bound is already inside its own noise envelope.** Worst observed median
4.637 s; observed run-to-run spread 1.89×. One further draw at the top of the
already-observed spread — `4.637 × 1.89 = 8.76 s` — breaches 8.0 on a run with
no regression present. This is not "eroding toward" a flake. It is one
ordinary bad run from being one, and per the m23-ab-1 precedent it would then
be misfiled as a flake for months. That is precisely the failure mode m23-as
exists to prevent, so leaving `:230` in place *is* the anti-pattern the item is
chasing — just not in the shape the item predicted.

**Run D is the important sample and is worth naming:** its median rose 1.89×
over the best run while its p90 (11.06 s) was **the second-lowest of the five**
(run C's 11.04 s is marginally lower) and its max (20.57 s) was mid-range.
> ⚠️ **CORRECTED by the orchestrator, 2026-08-03.** This sentence read *"was
> the lowest of the five"*, which contradicts this section's own table
> (C = 11.041 s < D = 11.059 s). This is one of the two derived statistics the
> design pass flagged as needing correction before it stalled; it never
> applied them. **The inference is unaffected** — D's p90 still sits at the
> bottom of the observed range while its median sits at the top, which is the
> semi-independence the argument needs. The distribution got fatter in the middle without
the tail moving. Consequence: **median and tail move semi-independently**, so
any scheme that couples a median bound to a tail-derived horizon must absorb a
shape ratio that itself ranges 4.44–10.15 (a 2.3× spread). §5.6 rejects such a
scheme on exactly this evidence.

### 3.1b The m23-as-2 IMPLEMENTATION campaign (added by the implementer)

MEASURED 2026-08-03 on this tree by the implementing agent. Run **F** is the
pre-edit baseline taken on the exact tree the edit was made against; runs
**G–K** and the **adversarial** run are post-edit. Every run below was verified
green — `grep -c '✘'` = 0 — and printed `Test run with 4692 tests in 483
suites passed` (F) / `Test run with 4693 tests in 483 suites passed` (G–K and
adversarial; the +1 test is the new discriminator, +0 suites).

The adversarial run is the m23-ab-2 protocol: 20 extra CPU-bound background
processes (PID-exact `kill -9` afterwards), suite wall 164.5 s against a ~95 s
norm.

| run | min (s) | median (s) | p90 (s) | max (s) | **under1s** (of 32) | suite wall (s) |
|---|---|---|---|---|---|---|
| full suite F (pre-edit) | 0.055827 | 3.567406 | 13.173 | 17.111 | — | 93.827 |
| full suite G | 0.070061 | 3.645403 | 14.370 | 15.455 | **9** | 97.460 |
| full suite H | 0.057818 | 4.321532 | 12.566 | 14.897 | **9** | 97.840 |
| full suite I | 0.062069 | 2.291965 | 13.847 | 27.326 | **9** | 98.064 |
| full suite J | 0.065253 | 2.443291 | 13.427 | 14.520 | **8** | 94.951 |
| full suite K | 0.049420 | 3.294276 | 13.001 | 18.105 | **8** | 103.819 |
| **ADVERSARIAL** | 0.161555 | 2.777165 | 23.920 | 37.304 | **8** | 164.456 |
| full suite L (final verify) | 0.056466 | 2.447989 | 12.043 | 22.101 | **9** | 703.304 † |
| full suite M (final verify) | 0.062917 | 2.314688 | 15.111 | 26.447 | **9** | 111.013 |
| full suite N (final verify) | 0.048030 | 2.489122 | 12.251 | 24.346 | **9** | 93.855 |
| full suite O (final verify) | 0.085794 | 2.738358 | 12.450 | 17.271 | **8** | 94.120 ‡ |
| isolated (`--filter`, post-edit) | 0.000190 | 0.000766 | 0.014669 | 0.048470 | **32** | 1.806 |

Runs **L**, **M**, **N** and **O** are the verification runs taken on the
shipped tree (i.e. *with* `#expect(underCleanPathBudget >= 4)` in place). **N
is the authoritative green full-suite run: `Test run with 4693 tests in 483
suites passed`, `grep -c '✘'` = 0, 93.9 s, port 8001 verified free
afterwards.**

Run **O** moved the worst full-suite `min` from 0.079429 to **0.085794 s**, so
the source comment's headroom figure was re-derived to **11.7×** (still far
above §6.1's 5× floor: 5 × 0.0858 = 0.43 s, well under the 1.0 s budget). Every
other channel landed inside the existing ranges.

‡ **Run O carried 8 `✘` lines / 3 failing tests, none of them in this file or
this module, and the cause is MEASURED rather than assumed.** All three are
`InsertSpectrumChainTests` legs asserting
`snapshot.bands.firstIndex(of: peak) == MasterMixAnalyzer.bandIndex(containing: 750)`
and all three got band 8 instead of 11. They reproduce **in isolation with this
file's suite filtered out entirely** (`--filter InsertSpectrumChainTests`, 11
tests, 0.148 s, same 3 issues), which is conclusive that this work is not
involved. Root cause: the machine's default output device became **"Dima
AirPods Pro" running at 24 000 Hz** (Bluetooth; `system_profiler
SPAudioDataType` → `Current SampleRate: 24000`). Those three legs build their
chain from a bare `PlaybackGraph(engine: AVAudioEngine())` with no injected
`graphRate`, so `PlaybackGraph.graphFormat()` (`PlaybackGraph.swift:2179-2186`)
falls through to `engine.outputNode.outputFormat(forBus: 0).sampleRate` and the
analysis tap runs at 24 kHz — while `tone(hz: 750, …)` is synthesised for
`Self.rate = 48_000`. The tone is therefore analysed as 375 Hz, which is
2.26 geometric bands low and lands on band 8. Their sibling legs pin the rate
explicitly (`state.sync(descriptors:sampleRate: Self.rate)` at `:170`/`:370`)
and stayed green. **This is a latent pre-existing device-dependence that turns
any non-48 kHz default output device into a red suite — worth its own roadmap
item. Not fixed here: it is out of scope, and the standing constraint forbids
touching the user's audio devices.**

† **Run L carried 4 `✘` lines, all one unrelated pre-existing flake, diagnosed
not assumed.** `WhisperTranscriberFixtureTests.concurrentJobsSerialise` wedged
for 11 minutes and then breached its own 300 s `.timeLimit`. A `sample` of the
test process showed the blocked frame exactly:
`WhisperTranscriberTests.swift:658 → makeSayFixture() (:489) →
-[NSConcreteTask waitUntilExit]`, with a live `/usr/bin/say` child (pid 81917,
elapsed 11:19) that never exited. Killing that child PID-exact released the
run. Nothing in `DAWEngineTests` and nothing on the AU prepare path is
involved; **this suite was green inside run L**, which is why its row stands.

**§6.3's gate: SATISFIED, and the assertion SHIPPED.** `C` = the worst
`under1s` across the five full-suite runs plus the adversarial run = **8**
(observations 9, 9, 9, 8, 8, 8). `m = floor(C / 2) = 4`, and `m >= 4`, so
`#expect(underCleanPathBudget >= 4)` ships. The count's run-to-run spread is
**1.13×** — the steadiest channel measured anywhere in this file, and it held
at 8 through a 3× whole-suite slowdown. It needs no discriminator of its own by
PROOF, not measurement: `under1s >= 4` ⇒ `under1s >= 1` ⇔ `min < 1.0`.

**§6.1's bound holds in both populations.** Full-suite worst min across A–K is
0.079429 s → **12.6× headroom**; adversarial worst is 0.161555 s → **6.2×
headroom**, which still clears §6.1's own 5× floor under a load the rule does
not even require it to survive. ⚠️ The two populations must be quoted
separately — an author who computes 6.2× against a comment claiming 12.6×
"discovers" an erosion that never happened.

**§7.4's discriminator gates: ALL PASSED.**

| gate | requirement | MEASURED | verdict |
|---|---|---|---|
| control-leg min | ≤ 0.25 s | 0.0124 / 0.0180 / 0.0385 / 0.0418 / 0.0176 s (G–K); 0.0220 s adversarial | **PASS**, worst 6.0× under |
| suite-time delta | ≤ 3 s | discriminator's own wall time 2.00–2.15 s loaded, 2.40 s adversarial | **PASS** |
| control count | raise to 16 only if min → 1.0 | worst 0.0418 s, 23.9× under budget | **not needed** |
| negative control | perturbation → 0 ms must redden | ✘ ×2: `regressedMin >= cleanPathBudgetSeconds` (actual **0.01547** against the 1.0 s budget) and `regressedMin − controlMin > 0.9` (actual **0.01364**); the anti-vacuity leg `controlMin < 1.0` stayed GREEN | **PASS**, reverted by editing and verified by grep |

⚠️ **Scope of the negative control, stated plainly:** it was run against the
tree *before* §6.3's `under1s >= 4` shipped. It therefore proves what §7 asked
it to prove — that the min bound and the difference cross-check both redden
when the perturbation is removed — and nothing about §6.3. That is not a gap:
§6.3's discriminator coverage is INHERITED BY PROOF (`under1s >= 4` ⇒
`under1s >= 1` ⇔ `min < 1.0`), not by that run. Line numbers are deliberately
omitted here; they moved when §6.3 landed, and the actuals are the evidence.

**§7.4's `α` read — §4.2 stays REASONED and is NOT closed.** MEASURED, six
runs: `minAmp` 1.488–1.570 s, `medianAmp` 1.465–1.533 s against a known 1.5 s
perturbation. Coefficient ≈ 1 in both channels, and `medianAmp` was never
*above* `minAmp` — so no median amplification is visible and §4.2 need not be
reopened on this evidence. ⚠️ But the scope is narrower than "α measured": the
perturbation sleeps OUTSIDE `dlsBankQueue` by design (§7.1), so it cannot
lengthen a gate critical section, which is precisely what `α` scales. This
confirms §4.1's additive pass-through; it does not measure `α`.

**§2.3's flag is now materially stronger.** Max reached **27.326 s (46 % of the
60 s horizon) on a green full-suite run** and **37.304 s (62 %) adversarial** —
against the 24.886 s / 41 % this document flagged. Evidence for **m23-aw**, and
still NOT a reason to raise `testPrepareTimeout` (m23-at forbids it).

**One deviation from §8, measured and documented in-source: the suite gained
`.serialized`.** §7 did not consider that Swift Testing parallelises test
functions *within* a suite, so the discriminator's 12 extra `.soundBank`
prepares would have landed on the process-global `dlsBankQueue` *during* the
stress test's measurement window — changing the very load shape the `[measured]`
line is the continuity record of, and growing the shape the file header warns
against growing. `.serialized` restores comparability with runs A–F.
MEASURED confirmation that it serialises: suite wall ≈ stress + discriminator
(89.655 + 2.025 = 91.68 against 91.757 reported). MEASURED confirmation that
the shipped distribution is uncontaminated: post-edit min (0.0494–0.0701) and
median (2.292–4.322) both sit inside-or-below their pre-edit A–F bands, and
deviations are in the *faster* direction, which contamination cannot produce.

### 3.2 What I did NOT measure, and why

- The **`withinCleanPathBudget` count** (how many of 32 samples fall under
  1.0 s under load) — not derivable from four quantiles, and obtaining it needs
  a test edit, which this task forbids. §6.3 makes it a measurement-gated step
  with a written protocol.
- **A same-run trivial-main-actor-hop cost** — same reason. §5.3 rejects the
  estimator that would need it on structural grounds that do not depend on the
  number.
- **The gate-queue-depth amplification coefficient `α`** for the median. §4.2
  marks the claim resting on it as REASONED, not MEASURED, states the
  sensitivity, and §7.4 makes measuring it a required step of the
  implementation.

---

## 4. Regression-class analysis — the core deliverable

Model: for prepare *i*, wall time `T_i = W_i + Q_i` where `W` is real work
(MEASURED isolated median 0.00078 s, i.e. ~0.02 % of the loaded median) and `Q`
is scheduling/queue wait (main actor + `dlsBankQueue`), heavy-tailed, driven by
ambient harness load and by the test's own 8-way self-inflicted concurrency.

Regression classes, as named in the task:

- **(a)** uniform added work in every prepare (`W += d` for all *i*).
- **(a′)** growth of a `dlsBankQueue` critical section by `c` — the class this
  code is structurally most exposed to, since m18-d and m19-j both *added*
  serialized sections to that gate. Queue-position amplification means the
  *k*-th of ~8 concurrent prepares pays `k·c`.
- **(b)** a stall affecting only SOME prepares — raises median/p90, leaves min
  low.
- **(c)** re-introduction of the m19-e fault class. **It kills the test
  process. No timing channel is its detector** — the anti-vacuity counters at
  `:192-198` and process survival are. Listed only to be dismissed: no
  estimator choice below can affect (c), and no estimator choice should be
  argued on (c)'s behalf.
- **(d)** the m23-at fault class — a main-actor-bound deadline that cannot fire
  while the actor is wedged. Detected by `DeadlineRaceTests`, not here. This
  suite is a *victim* of the fix's second-order effect (prepares now run to
  completion, lengthening the queue everything else waits in), not a detector
  of the fault.

### 4.1 Class (a) — exact arithmetic, MEASURED

`min_i(W_i + Q_i + d) = d + min_i(W_i + Q_i)`. The added work passes through
the min channel with coefficient exactly 1, and likewise through the median.
So:

| estimator | trips class (a) at |
|---|---|
| `min < 1.0` | `d > 1.0 − 0.0794 = **0.921 s**` (worst loaded); `d > 0.99983 s` isolated |
| `median < 8.0` | `d > 8.0 − 4.6372 = **3.363 s**` (worst loaded); `d > 5.548 s` best loaded |

**`min < 1.0` is 3.7×–6.0× more sensitive to class (a) than `median < 8.0`.**
Its detection threshold also barely moves with load: **0.921–0.99983 s, a
9 % span across every measured condition (2.9 % across the five loaded runs
alone)**, against the median's **3.363–8.0 s, a 138 % span (65 % loaded-only)**.
A detector whose sensitivity is a function of ambient load is a detector whose
last green run tells you little about its next. For the class the file's own comment
calls the important one, the assertion under audit contributes nothing the one
above it does not already contribute, better.

### 4.2 Class (a′) — REASONED, with the sensitivity stated

Model: `min` gains ~`c` (the luckiest prepare is at queue head), `median` gains
~`α·c` where `α` is the median queue position, plausibly ~4 for 8-way
contention.

- `min` trips at `c > 0.921`.
- `median` trips at `c > 3.363/α` = 0.841 at α=4, 0.420 at α=8, 1.68 at α=2.

**MARKED REASONED.** `α` is unmeasured, and the comparison flips at α ≳ 3.65.
Two things to note honestly:

1. My own data argues `α` is *low*: MEASURED `max/min` is **397×**
   (24.886 / 0.0626, run C). Eight-slot queue position cannot produce 397×.
   Ambient main-actor variance therefore dominates the observed spread, not
   gate depth — which supports the conclusion (median ≈ min in sensitivity)
   while undermining the linear model used to reach it.
2. §7 gives the implementer an empirical read on `α` for free, and §8 step 4
   makes checking it **required**, not optional. If the perturbed leg shows
   median amplification ≫ min amplification, `α` is high and this section must
   be revisited.

Even at α=8 the median's advantage is 2.2×, bought at the price of a bound
that is one ordinary run from flaking (§3.1). That trade is not worth taking.

### 4.3 Class (b) — the median's ONLY unique coverage, quantified

`min` is blind to any stall that spares even one prepare. `median` over n=32
moves only when the affected fraction exceeds 50 %.

**`median < 8.0` detects: "more than half of the prepares got ≥ 3.36 s
slower".** That is the complete, honest statement of its unique value.

Assessment:

- The magnitude required is enormous — 3.4 s on a path whose true work is
  0.78 ms, i.e. a ~4 300× regression on a majority of samples.
- A regression that large hitting a *majority* would in most realisations hit
  *all* of them: there is no mechanism in `performPrepare` that spares exactly
  the fastest 40 %. In that case `min` catches it at 0.92 s, four times sooner.
- Nothing in this tree's history has produced this class. The historical faults
  are (c) process death and (d) a non-firing deadline.
- The channel that would actually see a 25–50 % stall is `p90`, which is
  correctly and permanently unasserted.

**Verdict: real but narrow, requires a ~4 300× regression, and is not worth a
bound that is one ordinary run from a misfiled flake.** §6.3 offers a
measurement-gated way to recover part of it at lower cost, and pre-authorises
abandoning it if measurement says no.

### 4.4 Summary matrix

| estimator | (a) uniform | (a′) gate section | (b) partial stall | (c) m19-e | (d) m23-at | load-robust? |
|---|---|---|---|---|---|---|
| `min < 1.0` | YES — d > 0.92 s | YES — c > 0.92 s | no — blind | n/a | n/a | **YES — 12.6× headroom, 1.52× spread** |
| `median < 8.0` | weak — d > 3.36 s, dominated | weak — c > 3.36/α, REASONED | **YES — >50 % affected by ≥3.36 s** | n/a | n/a | **NO — 1.73× headroom, 1.89× spread** |
| `median − k·hop` | dilutes with `k` error | same | same | n/a | n/a | NO — `k` = O(depth × concurrency), unknowable (§5.3) |
| `median / CPU-calibration` | no — healthy ratio spans 1.1→6 620 | no | no | n/a | n/a | **NO — inverted (§1.2)** |
| `median / hop-calibration` | no — ratio → 1 under load | no | no | n/a | n/a | NO — non-monotone (§5.3) |
| `median − min`, `median / min` | no | no | no | n/a | n/a | NO (§5.4) |
| `median(concurrent) − median(churn)` | no | right *shape* | partial | n/a | n/a | NO — n=12/side vs 0.05–25 s spread (§5.5) |
| `withinCleanPathBudget >= m` | YES — subsumes min at m≥1 | YES | **partial** | n/a | n/a | **UNMEASURED (§6.3)** |
| `max` / `p90` bound | — | — | — | — | — | **BANNED** — §3, and the existing `:212-215` |

---

## 5. The alternatives, and exactly why each loses

### 5.1 Alternative 1 (strongest) — keep both, re-derive the median constant

**Why it loses:** §2.1. The derivation rule has no solution. `4 × 4.637 =
18.55 s` sits above the 5.9–13.5 s band where prepares begin flipping
`.failed`, so the rule cannot produce a bound that is both calibrated and
meaningful. Any other number is a fresh guess, and a fresh guess in a channel
with 1.89× run-to-run spread will need re-guessing again — silently, because
nobody re-measures a green assertion. MEASURED context for the drift: the
constant was calibrated 2026-07-16 and the margin fell 4× → 1.73× by
2026-08-03, 18 days, entirely unobserved; the harness stood at 446 concurrent
suites when m23-ab-2 measured it on 2026-07-29 and at **483** on the runs
taken for this document five days later.

### 5.2 Alternative 2 (second strongest) — convert to a same-run calibrated ratio, as m23-as-2 prescribes

**Why it loses:** §1.2. The healthy ratio against a CPU calibration spans
≈1.1 (isolated) to ≈6 620 (loaded). Against a main-actor-hop calibration it is
non-monotone in the wrong direction: isolated, the numerator is work-dominated
and the denominator is ~0, driving the ratio up; loaded, both numerator and
denominator are queue-dominated, driving the ratio *down* toward the
concurrency amplification factor. A bound that is *looser* when the machine is
idle than when it is loaded is not a bound.

### 5.3 Difference against a same-run main-actor-hop probe

`median(prepare) − k·median(hop)` is the theoretically right shape for
additive contamination, and it still loses, on three counts:

1. **`k` is unknowable a priori.** The prepare does not wait `H` hops; it waits
   behind `dlsBankQueue` occupied by up to 7 sibling prepares *each of which is
   itself waiting on the main actor*. The effective coefficient is
   O(queue depth × concurrency), not O(suspension points), and it changes if
   anyone edits the test's shape — the very shape `:105-115` warns against
   changing.
2. **Medians do not add.** `Q` is heavy-tailed (MEASURED: max/min = 397×). The
   median of a sum of correlated heavy-tailed draws is not the sum of medians,
   so even a correctly fitted `k` leaves a large residual.
3. **Unmeasurable here.** Fitting `k` requires test edits this task forbids;
   shipping an unfitted `k` is a third guessed constant where the original
   complaint was about one.

**`MainActorStarvationProbe`
(`Tests/DAWEngineTests/MainActorStarvationGateTests.swift:295-314`) is
conceptually the right denominator and should NOT be promoted.** Cost:
`fileprivate`, env-gated on `DAWPRO_MEASURE_MAINACTOR == "1"`, and a 4 s timer
plus 2 s grace — ≥ 6 s added to a ~90 s suite, unconditionally, on every run.
Its `GapStats` measure a *single* main-actor hop's gap, and §5.3(1) shows there
is no established linear relation between that and the prepare's wait.
**Paying ~7 % of the suite's wall time for a denominator with no established
relation to the numerator is not justified.** Promote it when a site needs it
*and* the relation has been measured — not speculatively. Leave it
`fileprivate` and env-gated.

### 5.4 `median − min` and `median / min`

MEASURED, both fail immediately. `median − min` loaded = 2.39–4.58 s versus
0.0006 s isolated — `min` captures only the *floor* of `Q`, not its typical
depth, so subtracting it removes ~2 % of the contamination. `median / min`
loaded = 31–88, isolated = 4.6 — worse than the raw channel.

### 5.5 `median(concurrent holders) − median(churn prepares)`

The one genuinely load-cancelling shape available *within* the existing test:
both sets experience the same ambient `Q` during the same window and differ
only in gate contention, so the difference is common-mode in the additive
contaminant — the additive-world analogue of the m23-ab-2 ratio.

**Why it loses:** n = 12 per side (3 holders + 3 churn, × 4 iterations) against
a per-sample spread of 0.05–25 s. The standard error of each median is
comparable to the medians themselves; no `K` tight enough to detect anything
would survive the noise. Correct shape, insufficient sample. Recorded here so
it is not re-derived as a fresh idea.

### 5.6 Express the median bound as a fraction of `AUHostRegistry.defaultPrepareTimeout`

Superficially attractive — it is the "ONE home" move, it is what §1.2 of the
audit suggests, and it is what m23-aw proposes for `SoundBankHostingTests:99`.

**Why it loses, and this is worth writing down:** it couples a **median** bound
to a **max**-regime horizon, so the fraction must absorb the distribution's
shape ratio. MEASURED, that ratio is `max/median` ∈ **[4.44, 10.15]** — a 2.3×
spread across five green runs, driven by run D, where the median moved and the
tail did not (§3.1). The fraction is therefore itself a guess carrying 2.3×
uncertainty. **It relocates the guessed constant; it does not remove it.**

It also does not conflict with m23-aw the way it first appears to, and the
distinction is structural rather than a judgement call:

> At `SoundBankHostingTests:99` the printed number has **no assertion in any
> channel** — m23-aw adds the first one. Here the per-prepare channel is
> **already hard-asserted** (a breach of `defaultPrepareTimeout` flips
> `.failed`, and `.ready` reddens at `:141`/`:182`); only the aggregate *proxy*
> for it is being removed. Adding a first guard and removing a redundant proxy
> for an existing guard are not inconsistent policies.
>
> ⚠️ **CORRECTED by m23-aw's design, 2026-08-03.** The claim *"no assertion in
> any channel — m23-aw adds the first one"* is FALSE, in its stated reason —
> `SoundBankHostingTests.swift:151` is `try #require(status == .ready, …)`,
> exactly the same layer-1 hard bound this paragraph correctly identifies as
> already guarding the stress suite's per-prepare channel. T1's channel IS
> hard-asserted at the horizon; it never lacked a guard. **The conclusion
> survives unchanged** (m23-aw's design §2.1 item 4: doctrine permits the
> shape it ships; the case against a NEW per-run wall-clock `#expect` on T1 is
> arithmetic — §2.2–§2.5 of that design — not the absence of an existing
> guard). Recorded so the next author does not build on the false reason.

---

## 6. The recommended shape

### 6.1 `:229` — keep `minSeconds < 1.0`, value unchanged

MEASURED justification for the number, to replace the current comment's
reasoning: across five green full-suite runs the loaded min spanned
**0.0524–0.0794 s**, leaving **12.6× headroom** at the worst observation, with
a run-to-run spread of only **1.52×** — the tightest of the two ASSERTED
channels (the median's is 1.89×).
> ⚠️ **CORRECTED by the orchestrator, 2026-08-03.** This read *"the tightest of
> the four channels"*, which contradicts §3.1's own table: p90 (1.28×) and max
> (1.35×) are both tighter, making `min` third of four. This is the second of
> the two derived statistics the design pass flagged before it stalled.
> **The recommendation is unaffected** — it rests on HEADROOM (12.6× vs 1.73×),
> not on spread rank, and among the channels actually asserted the claim holds.
> ⚠️ **Implementers: do NOT copy the phrase "tightest of the four channels"
> into the source comment.** The two tighter channels are p90 and max, and both
> are permanently BANNED from assertion (§4.4) — citing their stability as a
> virtue of `min` would be an argument for asserting them.
Isolated it is 0.000168 s. The bound therefore means the same thing in both
environments, which is exactly the property `:230` lacks.

Re-derivation rule when it erodes — state it in-source so the next author does
not have to invent one:

> **Re-measure the loaded min across ≥ 5 green full-suite runs. The bound must
> retain ≥ 5× headroom over the worst observation. If it cannot, the prepare
> path has changed by more than an order of magnitude and the correct response
> is an investigation, not a new constant.**

Unlike `:230`'s rule, this one has a solution today (5 × 0.0794 = 0.40 s, well
under 1.0) and degrades legibly rather than silently.

### 6.2 `:230` — delete the assertion, keep the print

Delete `#expect(median < 8.0)`. Keep `median` (and `p90`, and `max`) in the
`[measured]` line. The print is the continuity record that m23-ab-3, m23-at,
m23-aw and this document all depend on; the roadmap's preservation requirement
binds.

**Print changes are ADDITIVE ONLY — append fields, never reorder, rename or
remove existing ones.** Two fields to append, both cheap, both preventing a
recurrence of the defect this design found:

1. `under1s <count>` — the raw material for §6.3, and useful evidence whether
   or not §6.3's assertion ever ships.
2. `horizon <AUHostRegistry.defaultPrepareTimeout>` — so the record itself
   states the timeout that actually applied. §2.1's void clause survived
   because a reader could only learn the real horizon by chasing
   `TestEnvironment.isRunningTests` through two modules. Printing it makes that
   whole class of staleness self-correcting.

### 6.3 OPTIONAL, MEASUREMENT-GATED — `withinCleanPathBudget >= m`

```swift
let withinCleanPathBudget = seconds.filter { $0 < 1.0 }.count
#expect(withinCleanPathBudget >= m)
```

Rationale: it recovers part of class (b) — a majority-affecting stall evicts
those samples from the fast bucket — at zero added runtime, and it reuses the
**already-justified** boundary 1.0 s rather than introducing a second
magnitude. `m` is the only new number.

**Do NOT describe this as "load-tolerant by construction because it is an order
statistic."** That claim is wrong and must not enter the source comment. Order
statistics resist *outliers*; the contaminant here is a *distribution shift*
(min moved 312–473×, median 3 143–5 945×). A count against a fixed boundary is
sensitive exactly where load moves mass across that boundary, and load moves a
great deal of mass. This relocates the load sensitivity into a channel we can
bound — a count is bounded in [0, 32] and monotone — it does not remove it.

**Gate — the implementer must satisfy ALL of the following before shipping it:**

1. Land §6.2's `under1s` print field first, then take **≥ 5 green full-suite
   runs** plus **1 adversarial run** (≥ 20 CPU-bound background processes — the
   m23-ab-2 protocol at `EQCurveEditorModelTests.swift:780-782`).
2. Let `C` = the **worst (lowest)** `under1s` observed across all six.
3. Ship `m = floor(C / 2)` — the same 2× margin discipline `testPrepareTimeout`
   was derived under — **only if `m >= 4`.**
4. **If `m < 4`: DO NOT SHIP IT.** Ship §6.1 + §6.2 alone and record the
   measured `C` values in §3 of this document. A gate degenerating toward
   `m = 1` is `min < 1.0` re-spelled with extra ceremony, and a gate at `m = 2`
   or `3` sits inside its own sampling noise — the exact defect being removed
   from `:230`.

**This terminal state is pre-authorised.** Shipping §6.1 + §6.2 with no
replacement assertion is a complete and correct outcome of m23-as-2 for this
site. The implementer must not invent a substitute in order to avoid it.

### 6.4 Failure modes of the recommendation

| failure mode | likelihood | mitigation / accepted |
|---|---|---|
| Class (b) becomes real later and nothing catches it | low — §4.3: needs a ~4 300× regression on >50 % of samples | the `median`/`p90` print still records it; §6.3 if measurement allows |
| Someone reads the deletion as "timing is unbounded here" and adds a `max` bound | **moderate — the likeliest harm of this change** | the in-source comment must carry §3's table and an explicit prohibition; §8 step 3 makes it a required edit |
| `min < 1.0` erodes next | low — 12.6× headroom, 1.52× spread | §6.1's re-derivation rule, written in-source |
| The discriminator's control leg reddens under adversarial load | moderate — it is a min-of-8, not a min-of-32 | §7.4; an honest red, and §7.4 fixes the response so it is not "loosen the budget" |
| The deletion is read as precedent for deleting *any* inconvenient timing bound | moderate | §9's law is the guard: **measure the inflation factor first.** Deletion is licensed only where a ratio is shown inverted *and* the channel is shown dominated by a surviving one |

---

## 7. Mutation-discriminator design

Requirement from m23-as-2: the retained bound must demonstrably TRIP on a
synthetic regression. Reference: `recomputeRegressionTripsCalibratedBudget`
(`Tests/DAWAppKitTests/EQCurveEditorModelTests.swift:881-927`) — perturb the
real thing, then assert the same assertion shape now goes the other way.

### 7.1 The perturbation: the `instantiator` seam, NOT the gate

Perturb via `AUHostRegistry.instantiator` — an internal `@MainActor var`
already reachable through this file's existing `@testable import DAWEngine`,
and already used in exactly this idiom at
`Tests/DAWEngineTests/AUHostingTests.swift:158-162`:

```swift
let real = registry.instantiator
registry.instantiator = { description, options in
    let au = try await real(description, options)   // the REAL instantiate
    try? await Task.sleep(for: .milliseconds(1500))
    return au
}
```

**Why this and not the obvious alternative.** The tempting perturbation is to
occupy `AUHostRegistry.dlsBankQueue`, since class (a′) is the structurally
exposed one. **Reject it.** That queue is `static` and **process-global**
(`AUHostRegistry.swift:85-86`): seconds of deliberate occupancy would delay
every sibling suite's sound-bank prepare *in the same test process*, pushing
them toward their own 60 s timeout. A discriminator that can cause collateral
flakes in other suites is worse than the bound it validates. The `instantiator`
seam is **per-registry**, so its blast radius is exactly one prepare.

Three further properties make it the better model:

- The `await Task.sleep` **releases** the main actor, so it is a clean additive
  delay rather than actor hogging — it does not perturb the ambient `Q` the
  control leg is being measured against.
- It models a genuine regression class (a component's instantiate got slower;
  negotiation gained a round trip), not an arbitrary sleep in the test body.
- 1.5 s sits far inside the 60 s `DeadlineRace` window, so the perturbed
  prepare still reaches `.ready` and the discriminator measures latency rather
  than accidentally testing the timeout path. **State that constraint
  in-source** — it is what stops a future author raising the perturbation to a
  value that trips the deadline instead.

### 7.2 Sizing

The perturbation must exceed `budget − loaded_min_floor` = `1.0 − 0.0794 =
0.921 s`. At 1.5 s the perturbed leg's min has a **deterministic floor of
1.5 s** — i.e. **1.63× margin that cannot erode under load**, because a
`Task.sleep(for:)` of fixed wall duration can only be made *longer* by
contention, never shorter.

This is structurally stronger than the EQ precedent, where load could move the
ratio in either direction and 4× had to be escalated to 8×. No equivalent
escalation is needed here. (REASONED until §7.4's runs land.)

### 7.3 Shape — anti-vacuity guarded, same run

```
@Test("m23-as-2 discriminator: a +1.5 s instantiate regression trips the clean-path budget")
func instantiateRegressionTripsCleanPathBudget() async
```

1. **CONTROL leg** — 8 sequential unperturbed prepares (fresh registry each,
   released after), collecting seconds.
2. **REGRESSED leg** — 4 prepares, `async let`-concurrent, each on a fresh
   registry with the wrapped `instantiator`. Concurrency here is a cost
   decision: the 1.5 s sleeps overlap, so wall cost is ~1.5–2 s rather than
   6 s, and the sleep does not hold the gate, so the concurrency adds no gate
   pressure. Each must `#expect(status == .ready)` — a perturbation that
   *failed* the prepare would satisfy the latency assertion for the wrong
   reason.
3. **Print** a `[measured]` line in the file's existing idiom.
4. **Three assertions, in this order:**

   - `#expect(control.min()! < 1.0)` — **ANTI-VACUITY.** If ambient load alone
     breached the budget, this reddens too, and the discriminator cannot claim
     a false success. This assertion is the entire reason the design is
     trustworthy; it must not be dropped as "redundant with the shipped test".
   - `#expect(regressed.min()! >= 1.0)` — **THE DISCRIMINATION.** The same
     assertion shape the shipped leg is held to, now going the other way.
   - `#expect(regressed.min()! - control.min()! > 0.9)` — **the load-cancelling
     cross-check.** Because the perturbation is deterministic and additive,
     `regressed.min ≈ control.min + 1.5`; both legs draw `Q` from the same
     distribution in the same window, so the difference is common-mode in the
     contaminant. This is the one genuinely load-invariant statement available
     anywhere in this file, and it costs nothing. Lower bound only — do **not**
     add an upper bound; a slow control leg would make it fragile for no gain.

### 7.4 Gates on the discriminator itself

- Measure `control.min()` across **≥ 5 green full-suite runs**. It must stay
  **≤ 0.25 s** (4× margin under the 1.0 s budget). A min-of-8 is a weaker
  estimator than the shipped test's min-of-32, and this is the check that
  catches the difference.
- If `control.min()` approaches 1.0: **raise the control count to 16 first**
  — cheap, because these prepares hit the warm process-global DLS bank cache
  and cost ~0.8 ms isolated. Only if that fails should the discriminator move
  behind an env gate. Do **not** respond by loosening the budget: it is shared
  with the shipped assertion, and loosening it silently weakens `:229`.
- Report the **measured suite-time delta** (before/after, ≥ 3 runs each).
  Budget ≤ 3 s on a ~90 s suite. If exceeded, cut the control leg to 4 and the
  regressed leg to 2 before touching the 1.5 s constant.
- Record the discriminator's own `[measured]` numbers back into §3 of this
  document. **In particular: compare the MEDIAN amplification to the MIN
  amplification in the perturbed leg. That is the free empirical read on `α`
  which §4.2 flags as the one unmeasured coefficient in this analysis. If
  `α ≳ 8`, reopen §4.2.**

---

## 8. Implementation plan

Route: `qa-test-engineer`. All paths absolute.

**Step 1 — print fields (additive only).**
`/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift:209-211`.
Append `under1s <count>` and `horizon <AUHostRegistry.defaultPrepareTimeout>`
to the existing `[measured] m19-e contended prepares:` line. **Do not touch the
existing `n=`, `min`, `median`, `p90`, `max` field order or spellings** — every
prior measurement in ROADMAP and in this document parses against them.

**Step 2 — delete `:230`.** Remove `#expect(median < 8.0)`. Leave the `median`,
`p90` and `maxSeconds` computations and the print intact.

**Step 3 — rewrite the comment block `:200-228`.** Required content, all four
items:

- §3's five-run measured table, verbatim, with dates and green-run provenance.
- The **explicit prohibition** on adding `max`/`p90` bounds, with the numbers
  behind it. §6.4 rates "someone helpfully adds a max bound" the likeliest harm
  of this change.
- Why `:230` was deleted: §2.1's unsatisfiable-rule arithmetic, in one
  paragraph, plus a pointer to this document.
- §6.1's re-derivation rule for `:229`.

**Step 4 — fix the four stale 10 s references.** Lines **30**, **200-201**,
**216-217** and **228** of the same file each state or imply a 10 s horizon.
The applicable value is `AUHostRegistry.defaultPrepareTimeout` = 60 s in a
Swift test process. **Reference the named constant, never a literal** — that is
what stops the next drift. Lines 28-29's mention of the historical 10 s
`SoundBankHostingTests` timeout is a past-tense statement of fact and should
stay, but must be marked as historical so it is not read as current policy.

**Step 5 — add the discriminator** per §7, in the same file: it needs
`bankTrack` and `timedPrepare`, both `private` members of the suite.

**Step 6 — the `Duration`→seconds helper.** Currently inline at `:202-204`; the
discriminator needs it too. Extract to a `private static func secondsOf(_:)` on
the suite — **not** to a shared module. If a later site in this target needs
it, create
`/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/Support/TimingSeconds.swift`
(module-local, no product surface, no new SPM target).
**It must NOT go in `DAWCore`.** DAWCore stays headless and dependency-free and
carries the shipping domain model; a test-timing helper there would ship test
scaffolding into a product library. There is no `TestSupport` target in
`/Users/dsemenov/Views/daw-pro/Package.swift` today, and one helper does not
justify creating one.

**Step 7 — §6.3's measurement campaign**, then either ship
`withinCleanPathBudget >= m` or record the terminal state. This step may land
separately; steps 1–6 are complete and correct without it.

### Test strategy

- `./scripts/test.sh --filter AUPrepareRenegotiationStressTests` — isolated
  sanity. Confirm the printed test count is what you expect: `--filter` is a
  substring match on **type** names, not `@Suite` display strings.
- **≥ 5 green full-suite runs**, backgrounded, ~90 s each.
  **`./scripts/test.sh` EXITS 0 ON FAILURE — grep `^✘` and confirm the
  `Test run with N tests in M suites passed` line on every run.** Baseline to
  differ against: **4692 tests / 483 suites, 0 `✘`** (measured on runs D and E
  for this design). Expect **+1 test, +0 suites** from step 5, and no count
  change from steps 1–4.
- **One adversarial run** under ≥ 20 CPU-bound background processes, per the
  m23-ab-2 protocol. Its job is §7.4's control-leg check and §6.3's `C`.
- **Negative control for the discriminator:** temporarily set the perturbation
  to 0 ms and confirm `#expect(regressed.min()! >= 1.0)` **reddens**. A
  discriminator that passes with its own perturbation removed is proving
  nothing. Revert immediately; do not commit the mutant. Note that
  `git checkout`, `stash`, `restore` and `clean` are FORBIDDEN in this tree —
  reverse the edit by editing, and verify by reading the file back.
- Record every `[measured]` line produced into §3 of this document.

### Standing constraints for the implementing agent

Control port 17600 is the user's live app — never touched; staging is 17695.
No commits without the user's word. No `git checkout/stash/restore/clean`. Do
not touch `.env`, user audio devices, `scripts/ace-step/` or `scripts/rvc/`.
Verify port 8001 is free after any run that could have started the ACE sidecar.
This work does not require full Xcode.

---

## 9. The transferable law, for the other four m23-as-2 sites

Do not apply the ratio conversion blind. **One cheap measurement decides the
instrument at every site:**

> **Measure the same assertion's underlying quantity ISOLATED and under a full
> parallel suite, and take the inflation factor.**
>
> - **~2–10×** → the contaminant is **CPU contention**, which is
>   **multiplicative**. A same-run CPU-calibrated **RATIO** is the correct
>   instrument (`EQCurveEditorModelTests`, whose measured healthy ratio spans
>   only [0.494, 1.192] across isolated / full-suite / adversarial).
> - **~100×+** → the contaminant is **QUEUEING**, which is **additive**. A
>   ratio is **inverted**. Look for a same-run **DIFFERENCE** against a control
>   carrying the same additive term, or accept an absolute bound on the *most
>   robust channel* and write down its re-derivation rule.
>
> This site measures **312–5 945×**.

Corollary — the pair of half-truths stated in full: **a ratio cancels
multiplicative noise, not additive; a subtraction cancels additive noise, not
multiplicative.** Choosing between them requires knowing which contaminant you
have, and the inflation factor is how you find out. **Recommend recording this
as a law in `daw-pro-gate-laws` at close-out.**

**Hypotheses for the remaining sites — to be TESTED by that measurement, NOT
adopted as verdicts:**

| site | hypothesis |
|---|---|
| `Tests/DAWEngineTests/AudioContentAnalyzerTests.swift:677` | `analyze()` on a 5-minute WAV is CPU/IO-bound work, not queue wait. **Ratio probably fits.** Highest-confidence conversion of the four. |
| `Tests/DAWCoreTests/DeadlineRaceTests.swift:197` | Scheduling-dominated by construction — it measures a deadline race. **Ratio probably does NOT fit.** Expect an outcome shaped like this document's. |
| `Tests/DAWEngineTests/MIDIControllerInstrumentTests.swift:439` | Already a same-run subtraction; the open question is whether the dense/empty asymmetry is multiplicative. Measure both legs' inflation **separately** — if they inflate by the same factor, the subtraction is fine as-is and only the absolute 100 µs ceiling is exposed. |
| `Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift:1061` | Interleaved-min difference of two render-thread costs; likely genuinely CPU-bound, so the *absolute* 3000 ns ceiling is the exposed part, not the difference shape. |

---

## 10. Documentation follow-ups for the parent agent

This task authorised **one** file: this document. Nothing else in the tree was
edited. Below is proposed wording for the parent to apply.

### 10.1 `docs/ROADMAP.md:796` (m23-as-2)

The line currently prescribes *"6 absolute wall-clock bounds to convert to
same-run calibrated ratios"* and names *"the target shape is
`EQCurveEditorModelTests:831-918` (ratio against a same-process same-run CPU
calibration…)"*. **Proposed correction, to be APPENDED rather than replacing
the existing text — the item's correction history is load-bearing:**

> ⚠️ **THE "CONVERT TO A RATIO" PRESCRIPTION IS WRONG FOR
> `AUPrepareRenegotiationStressTests`, ADJUDICATED 2026-08-03 in
> `docs/research/design-m23as2-prepare-estimator.md`.** MEASURED, five green
> full-suite runs: the prepare's isolated→loaded inflation is **312–5 945×**,
> which is queueing, not CPU contention — and a ratio cancels MULTIPLICATIVE
> noise, not ADDITIVE, so the prescribed shape is INVERTED here (healthy ratio
> spans ≈1.1 isolated to ≈6 620 loaded). **`:229` (`min < 1.0`) is KEPT** —
> 12.6× headroom, 1.52× run-to-run spread, and 3.7–6.0× MORE sensitive to a
> uniform regression than the median bound. **`:230` (`median < 8.0`) is
> DELETED, print retained.** Its derivation rule ("4× the worst measured
> median") has stopped having a solution: worst median is now **4.637 s** (not
> the 2.02 s it was calibrated against, and not the 3.15 s an earlier reading
> gave), so the rule demands 18.55 s while prepares begin flipping `.failed` at
> a median of 5.9–13.5 s. ⚠️ Its second clause, *"still under the 10 s timeout
> horizon"*, has been **VOID since m23-at** — `timedPrepare` passes no
> `timeout:`, so the applicable horizon is
> `AUHostRegistry.defaultPrepareTimeout` = **60 s** in a test process.
> **THE LAW THAT GENERALISES TO THE OTHER FOUR SITES: measure the
> isolated→loaded inflation factor FIRST — 2–10× means CPU contention and the
> ratio works; 100×+ means queueing and the ratio is inverted.** ⚠️ Max is now
> **24.9 s = 41 % of the 60 s horizon** — evidence for m23-aw, and NOT a reason
> to raise `testPrepareTimeout` (m23-at forbids it).

### 10.2 `docs/ARCHITECTURE.md` — "Key future decisions"

Proposed entry, settling the estimator question at the architecture level:

> **Timing assertions in tests — which instrument.** SETTLED 2026-08-03
> (m23-as-2, `docs/research/design-m23as2-prepare-estimator.md`). There is no
> single correct shape. **Measure the quantity isolated and under the full
> parallel suite; the inflation factor picks the instrument.** ~2–10× is CPU
> contention (multiplicative) → a same-run CPU-calibrated **ratio**, K derived
> from measured spread across isolated / full-suite / adversarial load
> (`EQCurveEditorModelTests`). ~100×+ is queueing (additive) → a ratio is
> **inverted**; use a same-run **difference** against a control carrying the
> same additive term, or an absolute bound on the most robust channel with a
> written re-derivation rule (`AUPrepareRenegotiationStressTests`). A ratio
> cancels multiplicative noise, not additive; a subtraction cancels additive
> noise, not multiplicative. Every retained bound needs a mutation
> discriminator with a same-run **anti-vacuity control leg** — a bound nobody
> has seen fire is a bound nobody has calibrated, and a discriminator with no
> control leg can succeed for the wrong reason.

### 10.3 `docs/research/m23-as-timing-probe-audit.md`

§6 of that document is authoritative over §1.2 for this file and should gain a
pointer to this one, plus the run D/E rows — its table stops at run C, and its
"margin eroded 4× → 2.5×" figure is superseded by **4× → 1.73×**.

---

## 11. MEASURED vs REASONED — the ledger

**MEASURED** (this tree, 2026-08-03, from `[measured] m19-e contended prepares`
lines and from source read directly):

- The five-run loaded table and the isolated row (§3). Runs D and E are mine:
  `./scripts/test.sh`, backgrounded, verified `4692 tests / 483 suites passed`
  with 0 `✘` each; port 8001 free afterward. Runs A/B/C are the task brief's,
  reproduced unchanged.
- Per-channel run-to-run spread: min 1.52×, median 1.89×, p90 1.28×, max 1.35×.
- Headroom: min 12.6×, median 1.73×.
- Isolated→loaded inflation: min 312–473×, median 3 143–5 945×.
- Class (a) detection thresholds: min at `d > 0.921 s`, median at
  `d > 3.363 s` — exact arithmetic on measured values, since
  `min(W+Q+d) = d + min(W+Q)`.
- `max/median` ∈ [4.44, 10.15]; `p90/median` ∈ [2.38, 4.98]; `max/min` = 397×.
- Max = 24.886 s = 41 % of the 60 s test horizon.
- `AUHostRegistry.defaultPrepareTimeout` resolves to `testPrepareTimeout` =
  60 s under `./scripts/test.sh`: the wrapper runs `swift test
  --disable-xctest`, whose harness binary is `swiftpm-testing-helper`, the
  first branch of `TestEnvironment.isSwiftTestProcess`. `timedPrepare` passes
  no `timeout:`, so it takes the default.
- The `instantiator` seam is an internal `@MainActor var`, already used in this
  exact idiom at `Tests/DAWEngineTests/AUHostingTests.swift:158-162`.
- `dlsBankQueue` is `static` and process-global
  (`Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:85-86`).
- No `TestSupport` target exists in `Package.swift`.
- `EQCurveEditorModelTests`' calibration denominator: ~0.0007 s typical,
  0.0015–0.0016 s adversarial; its healthy ratio spans [0.494, 1.192].

**REASONED** (defensible, not measured — do not cite as data):

- §4.2's class (a′) analysis. The queue-depth amplification coefficient `α` is
  unmeasured, and the min-dominates conclusion flips at α ≳ 3.65. The measured
  `max/min` = 397× argues `α` is low, which supports the conclusion while
  undermining the linear model behind it. §7.4 makes measuring `α` a required
  step.
- §4.3's judgement that class (b) is not worth the bound. The class is real;
  "not worth it" is a call, made on the measured facts that it needs a ~4 300×
  regression on a majority of samples and that the bound costs a likely
  misfiled flake.
- The projection that 8.0 is "one ordinary bad run" from breaching. The
  arithmetic (4.637 × 1.89 = 8.76) is measured; treating a fifth-sample spread
  as predictive of a sixth draw is an inference from n=5.
- §6.3's `withinCleanPathBudget` viability. The count under 1.0 s is not
  derivable from four quantiles; the whole proposal is gated on measuring it.
- §7.2's claim that the discriminator needs no escalation to EQ-style 8×
  margins. It follows from `Task.sleep` having a deterministic wall floor, but
  is unproven until §7.4's runs land.
- §9's hypotheses for the other four sites. Explicitly hypotheses.
