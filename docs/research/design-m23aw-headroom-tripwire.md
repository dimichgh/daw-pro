# m23-aw — the AU-prepare headroom tripwire

**Status:** design, adjudicated, MEASURED. Written 2026-08-03 by `daw-architect`
against roadmap item m23-aw (`docs/ROADMAP.md:813`).

**Scope.** `Tests/DAWEngineTests/AUPrepareTimeoutPolicyTests.swift:66-70` (the
fake pin), `Tests/DAWEngineTests/SoundBankHostingTests.swift:94-158` (T1, the
site the item prescribes a fix at), and the harness-load surface that drives
both. It does **not** re-adjudicate `AUPrepareRenegotiationStressTests`' latency
contract — that contract stands, and §2.1 explains exactly how far it reaches.

**Full Xcode requirement: NONE.** No entitlement, AUv3, signing or bundling
surface is touched. Everything below runs under Command Line Tools via
`./scripts/test.sh` and `node`.

**Standing constraints honoured by this design:** no change to
`AUHostRegistry.testPrepareTimeout` (forbidden by m23-at, and now *guarded*);
the two `[measured]` print lines are extended ADDITIVELY only; the full-suite
and adversarial populations are never pooled; the pre- and post-policy regimes
are never averaged.

---

## 0. Decision

| question | verdict |
|---|---|
| the item's prescribed fix — `#expect(prepareTime <= 0.6 * testPrepareTimeout)` at `SoundBankHostingTests` T1 | **REJECTED AS A SWIFT ASSERTION.** The *shape* is not forbidden by doctrine (§2.1); the *number* and the *home* are refuted by measurement (§2.2–§2.4). |
| is the prescribed fix refuted by `AUPrepareRenegotiationStressTests`' point 4? | **NO — the parent agent's reading is over-broad.** Point 4 is scoped to that suite's own aggregate channels and to a different question. §5.6's carve-out for m23-aw is *factually wrong in its stated reason* and *right in its conclusion*. §2.1. |
| is 36 s (0.6 × horizon) safe? | **NO. MEASURED RED.** Adversarial full-suite run: T1 = **49.311 s**. The prescribed bound would have failed a run with no regression in it, by 37 %. |
| does *any* per-run wall-clock bound have a defensible value? | **NO. The interval is EMPTY, measured** (§2.5). Nothing simultaneously clears the adversarial observation and precedes the hard failure with usable lead. |
| the instrument that ships | **FOUR PARTS** (§5): a value pin that makes the forbidden move illegal; a structural main-actor-occupancy site pin; a print-continuity pin; and the statistical headroom check re-homed OUT of the Swift suite into `scripts/gates/m23aw-prepare-headroom.mjs`. |
| the fake pin at `AUPrepareTimeoutPolicyTests:66-70` | **DELETED, and replaced by a pin with teeth.** This is deletion of a TAUTOLOGY, not of a calibrated bound — §4.4 states why that is not precedent for m23-as-2's deletion. |
| `AUHostRegistry.testPrepareTimeout` | **UNCHANGED AT 60 s, and now pinned in two places so raising it breaks a test AND fails a gate.** |

**The one-sentence justification.** T1's prepare wall time is a measurement of
the *harness's ambient main-actor backlog*, and that is exactly the quantity
m23-aw is worried about — so the m23-as-2 rule inverts here and the contaminant
must NOT be cancelled; but the same fact means the channel inflates **1.59×**
under ordinary machine load, which puts every threshold that would give useful
lead time *below* a value the tree already produces on a green run, so the
watchable quantity has to move from the *symptom* (wall time, checked
statistically in a gate) to the *driver* (deliberate main-actor occupancy,
checked structurally in the suite).

### ⭐ The finding that outranks the item as filed

**m23-at's 2× headroom discipline is already violated, in fact, on this tree,
today — and the pin that supposedly enforces it is green.**

```
worst GM prepare, 5 green full-suite runs, 2026-08-03   30.994 s
AUHostRegistry.testPrepareTimeout                       60 s
actual margin                                           1.936×      (m23-at's stated discipline: 2×)
same channel under ordinary machine load                49.311 s  = 82.2 % of the horizon
```

`AUPrepareTimeoutPolicyTests:68` asserts `60 >= 2 × 27` and passes. The real
number is 30.994, so the real claim is `60 >= 2 × 30.994 = 61.99` — **false.**
The item said the literal "measures nothing"; the measurement says it is worse
than that. It is *wrong*, and it has been wrong since some point between
2026-08-02 and 2026-08-03.

---

## 1. The measurement campaign

### 1.1 Protocol

All runs `./scripts/test.sh`, this machine, this tree (uncommitted working
tree, **4712 tests / 486 suites**), all 2026-08-03, all **sequential** — a
parallel campaign would change the very load shape being measured. Failure
detection by `grep -c '^✘'`, never by exit status (`./scripts/test.sh` exits 0
on a failed run). Numbers read off the two existing `[measured]` lines:
`SoundBankHostingTests.swift:103` and `AUPrepareRenegotiationStressTests.swift:269`.

Three populations, **never pooled**:

- **P1 — NORMAL.** Unmodified tree, n = 5. All green (`Test run with 4712 tests
  in 486 suites passed`, `^✘` = 0).
- **P2 — CONTROLLED.** `--skip AUPrepareInFlightWedge`, n = 5. All green (4711
  tests / 485 suites). Isolates the one main-actor hog added on 2026-08-03.
- **P3 — ADVERSARIAL.** Unmodified tree under 20 CPU-bound background processes
  (the m23-ab-2 protocol; hogs torn down PID-exact, verified dead), n = 1. This
  run carried 1 unrelated ✘ (`AuditionEngineTests` C12, a queued-event count) —
  **no AU prepare timed out**, and the T1/stress rows are included on that basis.

### 1.2 T1 — `[measured] GM bank prepare-to-ready wall time` (seconds)

```
  population                       n   min      max      mean     spread
  P1  normal, unmodified tree      5   29.287   30.994   30.024   1.058×
  P2  normal, wedge suite skipped  5   26.710   29.923   28.251   1.120×
  P3  ADVERSARIAL (20 CPU hogs)    1   49.311   49.311   49.311   —

  P1 rows: 29.287  29.410  29.776  30.652  30.994
  P2 rows: 26.710  26.750  28.924  28.947  29.923
  P3 row : 49.311
```

### 1.3 The control channel — `[measured] m19-e contended prepares`, `max` (seconds)

Same runs, so this is a controlled comparison and not a second campaign.

```
  population   n   min      max      mean     spread
  P1           5   16.671   24.675   21.776   1.480×
  P2           5   14.096   26.899   21.522   1.908×
  P3           1   39.034   39.034   39.034   —
```

**This is the answer to "is T1 a materially different channel from the stress
suite's max-of-32?" — YES, and it is measured, not argued.** Between m23-as-2
(2026-08-03, earlier) and this campaign the stress `max` did **not** move
(24.675 today against 27.326 then — inside its own recorded 14.520–27.326
band), while T1 moved **26.9 → 30.994, +15 %**. Two channels, same runs, same
`AUHostRegistry.prepare` code path, opposite behaviour. T1 is a *single*
prepare in a `.serialized` suite whose wait is ambient main-actor backlog;
the stress `max` is an extreme order statistic over 32 deliberately
self-contending prepares, and its self-contention dominates its own ambient
term. **T1 is the leading indicator; the stress max is not.**

Corollary, and it matters for §2.1: point 4 of the latency contract was derived
on, and is scoped to, a channel that is empirically *not* the one drifting.

### 1.4 Derived figures

```
  W  = worst NORMAL-population T1 observation              30.994 s
  H  = AUHostRegistry.testPrepareTimeout                   60 s
  H/W = actual headroom                                     1.936×   (< 2 — m23-at's discipline, broken)
  W/H = horizon consumed on a green run                     51.7 %
  adversarial inflation, T1 channel      49.311 / 30.994 =  1.591×
  adversarial inflation, stress-max channel 39.034/24.675 = 1.582×   ← two independent channels agree
  headroom remaining below the wall, normal                29.006 s
  headroom remaining below the wall, adversarial           10.689 s
```

**The 1.59× agreement across two independent channels is what licenses treating
adversarial inflation as a COEFFICIENT rather than as a single draw.** That
distinction is load-bearing in §6.1 — using the adversarial run to derive a
coefficient and then applying it to the normal population is *not* pooling the
populations, and the design says so out loud because the file it borrows the
discipline from bans the pooling, not the coefficient.

### 1.5 The wedge experiment (P1 vs P2)

`Tests/DAWEngineTests/AUPrepareInFlightWedgeTests.swift:92-101` holds the main
actor with a **synchronous busy spin for 2 000 ms** (`hogDuration`), landed
2026-08-03 by m23-av, i.e. between m23-at's measurement and this one.

```
  mean delta (P1 − P2)          +1.773 s
  worst-to-worst delta          +1.071 s
  populations overlap?          YES (P2's worst 29.923 > P1's best 29.287)
```

**Verdict: real but partial, and SUGGESTED rather than measured.** One 2 s
main-actor hog costs the GM prepare roughly **0.5–0.9 s of horizon per second of
hog** — a coefficient consistent with the fact that a prepare re-acquires the
main actor three times (`design-m23as2-prepare-estimator.md` §1.1), so a hog is
charged more than once. n = 5 vs n = 5 with overlapping tails does **not**
carry that coefficient to a second significant figure and this design does not
claim it does.

**What it does NOT explain.** m23-at recorded 24.3–26.9 s (n = 6, a different
day); P2's worst is 29.923 s. Removing the hog does **not** return the channel
to the m23-at band. The residual is not separable from day-to-day machine
variation with the data available, and this design does not attribute it. It
is filed as m23-aw-2 (§11).

### 1.6 Structural counts (`git grep` at each revision, `Tests/` only)

```
  rev       date        @Suite   @MainActor suites   prepare/prepareEffect sites   files
  31a46aa   2026-07-13    283           191                    34                    7
  0bc2a51   2026-07-16    293           195                    39                    8
  abac1c1   2026-07-18    317           206                    40                    9
  8b163c9   2026-07-20    362           233                    43                   10
  3111398   2026-07-27    411           262                    43                   10
  0379644   2026-07-30    448           279                    43                   10
  5ca7944   2026-07-30    449           280                    43                   10
  working tree 2026-08-03  486          298                    60                   12
```

`@Suite` declarations (486) equal the runner's reported suite count (486) —
the structural count tracks the runner 1:1, which is what makes it usable as a
pin at all. `@MainActor`-isolated suites grow at ≈ **5.2/day**; the
prepare-issuing site count sits on **plateaus punctuated by AU cycles** (43
unchanged across five commits and ten days, then +17 in the uncommitted m23-at
/ m23-au / m23-av day).

### 1.7 The main-actor occupancy population, enumerated by rule

**The enumeration rule matters more than the number.** `grep 'MainActor.run {'`
returns 2 sites tree-wide and would have produced a pin that is blind to most of
its own population — the `_exitpaths.py` / `_classify.py` defect (m23-bm), one
cycle later. The defensible rule:

> A **deliberate main-actor hog** is a construct that (a) occupies the main
> actor or blocks the main thread, (b) *without suspending* — so `Task.sleep`
> and every `await` are excluded, (c) for a **fixed nominal wall duration** that
> is a constant in the source, and (d) inside a `@MainActor` context, (e) in a
> test that **runs by default** under `./scripts/test.sh` — i.e. carries no
> `.enabled(if:)` / `.disabled(…)` trait, directly or on its suite.

Scanning `Tests/` for `Thread.sleep(`, `usleep(`, `DispatchQueue.main.sync`,
`.wait()`, `waitUntilExit()` and clock-deadline busy spins yields **20 candidate
blocking sites**, of which clause (d)+(e) admit exactly **two**:

```
  Tests/DAWCoreTests/DeadlineRaceTests.swift:70            spinHoldingMainActor      1 000 ms  (:126)
  Tests/DAWEngineTests/AUPrepareInFlightWedgeTests.swift:99 the E1 hog               2 000 ms  (:85)
  ------------------------------------------------------------------------------------------------
  TOTAL DELIBERATE MAIN-ACTOR SPIN IN THE DEFAULT SUITE                             3 000 ms
```

The 18 rejected candidates and *why* each is rejected (this list is the pin's
audit trail, and a future author who widens the pin must start here):

- `MainActorStarvationGateTests.swift:418` `Thread.sleep(1.5 s)` — clause (e):
  `.enabled(if: MainActorStarvationProbe.isEnabled)`, skipped by default.
- `OutputDeviceLoopbackGateTests.swift:156/295/306/327/329/341/444` —
  clause (e): `.enabled(if:)`-gated.
- `RecoveryAnchorContinuityGateTests.swift:285/286/307` `usleep` — these DO run
  by default (their `@Test`s appear in every run's log; the file is an
  `extension RecoveryPlayheadTests`), but they sit in `static func`s reached
  from a live-engine probe and each is ≤ 200 ms with no `@MainActor` annotation
  on the enclosing declaration. **Clause (d) is UNPROVEN for these three, not
  disproven** — see §10.
- `LiveEventRingTests.swift:96`, `GaplessLoopTransportTests.swift:488`,
  `RecoveryOutputPinGateTests.swift:254` — busy loops whose bound is a
  *condition*, not a fixed duration (clause (c)); they exit as soon as the
  witness arrives.
- `ClipFixModelTests.swift:168` `await gate.wait()` — suspends (clause (b)).
- `ClipTranscribeRealFixtureTests.swift:53`, `WhisperTranscriberTests.swift:489`
  `process.waitUntilExit()` — blocks a thread, but not the main actor in a
  measured way, and the duration is a child process's, not a constant
  (clauses (c)/(d)).

---

## 2. Verdict on the prescribed fix

### 2.1 What doctrine does and does not forbid — the adjudication

The parent agent's reading is that `AUPrepareRenegotiationStressTests`' latency
contract, point 4 ("MEDIAN, P90 and MAX — RECORDED, NEVER ASSERTED. ⚠️ DO NOT
ADD A BOUND TO ANY OF THEM"), refutes the item's prescription. **It does not,
and the design must say so rather than win on a technicality it would then have
to defend forever.**

1. **Point 4 is scoped to its own file's aggregate channels.** Its own words:
   "a bound on *those channels* measures the harness's ambient load, not *this
   gate*." "This gate" is the m19-e race regression gate, whose job is to detect
   a *prepare-path* regression. Ambient load is that gate's contaminant.
2. **m23-aw asks the opposite question.** "Is the harness's ambient load
   approaching the horizon?" For that question ambient load is the *signal*.
   The same number, measured the same way, is noise for one question and data
   for the other. Point 4 does not reach across that boundary.
3. **§1.3 makes this empirical, not rhetorical.** T1 and the stress `max` moved
   in opposite directions over the same interval, on the same runs. Point 4 was
   derived on the channel that did not move.
4. **`design-m23as2-prepare-estimator.md` §5.6 already carved m23-aw out — for
   a reason that is FALSE.** It says: "At `SoundBankHostingTests:99` the printed
   number has **no assertion in any channel** — m23-aw adds the first one."
   That is wrong. `SoundBankHostingTests.swift:151` is
   `try #require(status == .ready, …)`, which is exactly the same layer-1 hard
   bound the stress suite has: a prepare that breaches `defaultPrepareTimeout`
   flips `.failed` and this `#require` reddens. T1's channel *is* hard-asserted
   at the horizon. **The carve-out's conclusion survives; its stated reason does
   not, and it should be corrected in place** (§8, step 7) so the next author
   does not build on it.

**So doctrine permits the shape.** What kills it is arithmetic.

### 2.2 The prescribed number is refuted by measurement

`0.6 × 60 s = 36 s`.

```
  headroom over the NORMAL-population worst (30.994 s)       1.162×
  headroom over the ADVERSARIAL observation (49.311 s)       0.730×   ← RED, by 37 %
```

The repo's own calibration standard, from the bound this project deleted one
item ago: `#expect(median < 8.0)` was removed for carrying **1.73×** headroom
against a channel whose run-to-run spread is **2.02×** — "the bound sat INSIDE
its own measured noise envelope, one ordinary bad run from a flake with no
regression present." The prescribed bound carries **1.162×**. It is not near the
line; it is on the wrong side of a line this project drew yesterday.

And it is not a hypothetical bad run. **A green tree under ordinary machine load
produced 49.311 s.** The prescribed bound would have reddened `SoundBankHosting-
Tests` — the AU suite — with a latency message, on a run with no regression in
it. That failure reads exactly like the m23-ab-1 flake this project spent months
misfiling.

### 2.3 It would be GREEN today while the discipline it encodes is already broken

30.994 < 36. The prescribed tripwire, shipped this morning, would pass — while
the actual headroom is 1.936× against a stated discipline of 2×. **A tripwire
that is green while the property it exists to protect is already violated is the
same defect as the literal it replaces, one regime over.** That is the strongest
single argument against shipping it: it would convert a *visibly* fake pin into
an *invisibly* fake one.

### 2.4 "60 %" silently loosens the 2× discipline it appears to enforce

`prepareTime ≤ 0.6 × H` is exactly `H ≥ 1.667 × prepareTime`. m23-at derived
`H = 60 s` as **~2.2× a measured 26.9 s**, and `AUPrepareTimeoutPolicyTests:69`
states the discipline as `>= measuredWorstCase * 2`. Shipping the 60 % form
writes **1.667×** into the tree as the enforced discipline, without saying so,
at the exact moment the real margin has fallen to 1.936×. It would encode the
violation as the new rule.

### 2.5 No per-run wall-clock bound has a defensible value — the interval is EMPTY

This is the §2.1-of-m23-as-2 move: show the derivation rule has no solution.

A bound `B` on T1's per-run `prepareTime` must satisfy both:

- **(i) it must not redden without a regression.** The measured population
  includes a green run at 49.311 s. `B ≥ 49.311`, and with any cushion at all,
  `B ≥ ~52`.
- **(ii) it must precede the hard `#require(.ready)` at 60 s with lead time
  worth having.**

```
  B      % of horizon   headroom over W   headroom over ADVERSARIAL   lead to 60 s
  36     60 %  (item)      1.162×             0.730×  RED               24 s
  40     67 %              1.291×             0.811×  RED               20 s
  45     75 %              1.452×             0.913×  RED               15 s
  48     80 %              1.549×             0.973×  RED               12 s
  50     83 %              1.613×             1.014×                    10 s
  52     87 %              1.678×             1.055×                     8 s
  55     92 %              1.775×             1.115×                     5 s
```

The first row that survives a *single already-observed* loaded run is `B = 50`,
at **1.4 % margin** — which is not a margin — and it buys 10 s of lead on a 60 s
wall. **The interval where (i) and (ii) both hold is empty.** Any `B` a future
author picks is either a flake generator or a duplicate of the hard bound that
already exists.

⚠️ One may reply that the adversarial population is out of scope by the
contract's own rule. It is out of scope **for deriving the number**; it is not
out of scope for asking *what breaks*. Excluding it means shipping an assertion
whose known failure mode is "the AU suite goes red when the user's laptop is
busy." The project has already paid for that lesson twice (m23-ab-1, m23-ab-2).

### 2.6 What the item got RIGHT

Three things, and they survive intact:

- **The loop is real and it is running.** 26.9 → 30.994 in about a day.
- **"Do NOT respond by raising 60 s"** — correct, and this design is the first
  thing in the tree that actually *enforces* it (§5.1).
- **"read the number that is already being printed"** — correct, and adopted.
  §5.3 reads exactly that number. The item's error was the *home*, not the
  instinct: the number belongs in a deliberate ≥5-run campaign, not in a
  per-run `#expect`. Remarkably, **36 s turns out to be very nearly the right
  threshold — as a worst-of-5 gate limit** (§6.1). The difference between "36 s
  asserted on every run" and "36 s asserted on the worst of five deliberate
  runs" is the difference between a flake generator and a tripwire.

---

## 3. The driver, and why the instrument-selection rule inverts here

### 3.1 The m23-as-2 rule, applied honestly

> *"Measure the inflation factor first; it, not taste, picks the instrument. A
> ratio cancels MULTIPLICATIVE noise, not additive; a subtraction cancels
> ADDITIVE noise, not multiplicative."*

The inflation is 294–5 945× → queueing → **additive**. The rule therefore points
at **subtraction**. And subtraction is *still* wrong here, for a reason the rule
does not cover and this design has to add:

> **The rule presumes the contaminant is not the quantity of interest.** In
> m23-as-2 the signal is prepare-path WORK and the queue is contamination, so
> cancelling the queue is progress. In m23-aw the signal **is the queue** — the
> item's entire worry is that ambient queueing will consume the 60 s horizon.
> Subtracting the queue from T1 leaves the ~0.02 % that is work
> (isolated median 0.000780 s), a quantity with no relationship to the horizon
> at all.

**Cancelling the contaminant here cancels the signal.** That is the decisive
rejection of option (b), and it is a genuinely new clause, not a re-derivation:
`design-m23as2-prepare-estimator.md` §5.4 already measured that the best
available same-run proxy (`min`) captures only the *floor* of Q and removes ~2 %
of the contamination, so even the mechanically-best subtractive instrument both
fails to cancel and cancels the wrong thing.

### 3.2 So the instrument must watch the driver, and the driver is occupancy

If the signal is ambient main-actor backlog, the thing to watch structurally is
**what the harness deliberately does to the main actor**. §1.5 measured one such
thing costing ~1.8 s of the horizon. §1.7 enumerated the population by rule: two
sites, 3 000 ms total.

This is measurable with zero flake risk, it is causally upstream of the wall
time, and — unlike the suite count — it moves in *deliberate acts* rather than
in continuous drift.

---

## 4. The alternatives, and exactly why each loses

### 4.1 (a) The literal prescription — horizon-fraction bound on T1's `prepareTime`

**REJECTED as a Swift assertion; RE-HOMED to a gate.** §2.2–§2.5. Kept in the
design in the only form that survives measurement: worst-of-N in a campaign,
outside the suite (§5.3).

### 4.2 (b) A subtractive instrument (`prepare − ambient-queue proxy`)

**REJECTED, twice over.** §3.1 (it cancels the signal, not the noise) and,
independently, `design-m23as2-prepare-estimator.md` §5.3/§5.4: `k` is unknowable
a priori (the coefficient is O(queue depth × concurrency), not O(suspension
points)); medians of heavy-tailed correlated draws do not add; and
`MainActorStarvationProbe` — conceptually the right denominator — costs ≥ 6 s of
unconditional suite time for a denominator with no established relation to the
numerator. Nothing in this campaign changes any of those; §3.1 adds the reason
the shape is wrong *even if* they were solved.

### 4.3 (c) Pin the LOAD, not the LATENCY

**ACCEPTED — but not on the channel first proposed, and split into two things
that were being merged.**

- **A THRESHOLD on suite count** ("suites ≤ N derived from a seconds-per-suite
  slope) is **REJECTED: the slope is UNMEASURED and cannot be measured from
  existing data.** 446 suites @ 20.4–23.0 s and ~482 suites @ 24.3–26.9 s differ
  by suite count *and* by the m23-at policy change, and the roadmap forbids
  averaging those regimes. §1.5 adds a second confound (an occupancy change) and
  §1.6 a third (uncommitted growth). No honest `ds/dN` exists.
- **A RATCHET** (pin the count where it is; movement forces a human read) needs
  no slope and cannot flake. **ACCEPTED**, on two channels:
  - **deliberate main-actor occupancy** (§1.7) — small (2 sites, 3 000 ms),
    causally validated (§1.5), moves only in deliberate acts. **This is the
    tripwire with real lead time.**
  - **`@MainActor` suite count** — 298, growing ≈ 5.2/day. Kept explicitly as a
    **REVIEW CADENCE**, not a physical threshold (§6.2), because §1.5's residual
    (P2's worst 29.923 s still exceeds m23-at's 26.9 s band) says generic growth
    is probably real even though it is not separable from machine variation.
  - **prepare-issuing call sites** (60 today, 43 at HEAD) — **REJECTED as a
    ratchet channel.** It is a proxy for `dlsBankQueue` pressure, which §1.3
    shows is the channel that did *not* drift; and its +17-in-one-day burst
    profile means it would fire on every AU cycle for a driver measured to be
    the weaker one. It is worth PRINTING, not asserting.

### 4.4 (d) Delete the fake pin, ship a re-derivation rule, assert nothing

**REJECTED as the whole answer** — the roadmap explicitly asks for a tripwire
and warns against documentation. **ACCEPTED as one quarter of the answer**: the
deletion happens (§5.1), and it is accompanied by three assertions that fire.

⚠️ **This deletion is NOT the m23-as-2 precedent and must not be cited as one.**
m23-as-2 deleted a *calibrated bound whose derivation rule had stopped having a
solution*. This deletes a **tautology** — `Duration.seconds(27) * 2 <=
Duration.seconds(60)`, two compile-time constants, an assertion that cannot
observe the program. Deleting a measurement that went stale and deleting a
statement that never measured anything are different acts, and only the first
one needs a precedent argument.

### 4.5 (e) Raise `testPrepareTimeout`

**FORBIDDEN** (m23-at's roadmap line; restated in m23-aw's own line). Worth
stating what this design adds: until now the ban was enforced *by memory only*
for the test-time constant — `AUPrepareTimeoutPolicyTests` pins the **production**
value against a literal and leaves the test value unpinned. §5.1 closes that,
and §5.3 adds an independent second check that the gate cannot be fooled by it.

### 4.6 (f) Derive the horizon at runtime from ambient load

An adaptive `testPrepareTimeout` (measure the harness at process start, scale the
timeout) **REJECTED.** It makes the horizon unfalsifiable, destroys the
continuity record every recorded measurement depends on, and is
"raise the number" with extra steps — automated, so nobody ever notices.

### 4.7 (g) Reduce the load: run AU suites in a second pass

`./scripts/test.sh --skip AU… ; ./scripts/test.sh --filter AU…` would cut the
ambient backlog for exactly the suites that suffer it. **DEFERRED, not
rejected** — and the trade must be stated because it is not obvious: the m18-d /
m19-e race the stress suite exists to catch **only reproduces under contention**
(pre-fix it fired 3×/run under organic full-suite load and never in isolation).
Halving the ambient load for AU suites would weaken the one gate that guards a
process-corrupting DLS race. Filed as m23-aw-1 (§11) so the trade is decided
deliberately, not as a side effect of a tripwire item.

### 4.8 (h) A process-global cumulative prepare counter asserted late in the run

**REJECTED.** The count is deterministic only for a *full* run; every
`--filter` / `--skip` invocation would produce a different value, and Swift
Testing offers no run-level teardown hook, so the assertion would have to live
in a test whose position in a parallel run is nondeterministic. A pin that is
wrong under `--filter` trains authors to ignore it.

### 4.9 (i) `count(prepare > 30 s) == 0` in the stress suite, in the `under1s` idiom

Superficially attractive: `under1s` is the steadiest channel ever measured in
this tree (1.13× spread, survived a 3× whole-suite slowdown). **REJECTED**: the
`under1s` channel is steady because its boundary (1.0 s) sits **11.7× below** the
mass of the distribution. A tail-side count at 30 s sits *inside* the tail —
P1's stress `max` reached 24.675 s and P3's 39.034 s — so the count would be
0 today and nonzero on any loaded machine. Relocating a bound into a count does
not move the boundary; it only changes what you call it.

---

## 5. The instrument that ships

Four parts. Each does one job, and they fail differently on purpose.

### 5.1 PART 1 — the anti-circumvention pin (Swift, runs every suite)

**File:** `/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/AUPrepareTimeoutPolicyTests.swift`

**DELETE** `testTimeoutHasHeadroomOverMeasuredWorstCase` (lines 66–70 today) —
the tautology.

**ADD**, in the same file and in the same idiom as the existing
`productionTimeoutIsTenSeconds`:

```swift
@Test("the test-time horizon is 60 s — raising it is the m23-at move, one regime over")
func testTimeoutIsSixtySeconds() {
    #expect(AUHostRegistry.testPrepareTimeout == .seconds(60))
}
```

**Why this is not the tautology it replaces.** The deleted assertion compared
two constants *about the world* and could not fail for any behaviour of the
program. This one pins **the one edit m23-at and m23-aw both forbid**. Today
nothing stops a future author from typing `.seconds(90)` when an AU suite goes
red; after this, that edit reddens a test whose name says why, and the gate in
§5.3 fails independently (§5.3's `horizon` leg), so the forbidden move cannot be
made quietly in either place.

**The doc comment carries the measurement**, replacing the stale 27:

- m23-at derived 60 s as ~2.2× a measured 26.9 s worst case (n = 8, mixed
  regimes; the post-policy sub-population was 24.3–26.9, n = 6).
- **m23-aw re-measured it 2026-08-03: worst 30.994 s over 5 green full-suite
  runs → actual margin 1.936×, i.e. BELOW the 2× the number was derived under.
  Under ordinary machine load the same channel reached 49.311 s = 82 % of the
  horizon.**
- The live headroom check is `scripts/gates/m23aw-prepare-headroom.mjs`; the
  structural early warning is `MainActorOccupancySiteTests`.
- Raising this constant is forbidden; the permitted response is load reduction
  (m23-aw-1).

### 5.2 PART 2 — the main-actor occupancy site pin (Swift, runs every suite)

**New file:** `/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/MainActorOccupancySiteTests.swift`

Idiom: `RenderClockTrustSiteTests` verbatim — locate the repo root by walking up
from `#filePath`, read `Tests/` as text, strip comment lines, scan, print
`[measured]`, assert against a written table. No bundle resources; runs headless
under `./scripts/test.sh`.

**Three legs.**

- **Leg A — THE LEDGER (set equality, not a count).** The set of deliberate
  main-actor hogs (rule in §1.7) must equal exactly:

  ```
    DeadlineRaceTests.swift            spinHoldingMainActor        1 000 ms
    AUPrepareInFlightWedgeTests.swift  <the E1 hog>                2 000 ms
  ```

  Set equality, with each entry carrying its enclosing symbol and its nominal
  duration constant — **a count pin is not sufficient** (the m23-bp lesson
  restated in `RenderClockTrustSiteTests:32-36`): swapping a 1 s hog for a 5 s
  hog keeps the total at 2 sites.

- **Leg B — THE BUDGET.** Summed nominal hog duration ≤ **3 000 ms** (today's
  measured total; §6.2 gives the re-derivation rule). Failure message states the
  measured coefficient (~0.5–0.9 s of GM prepare per 1 s of hog, SUGGESTED,
  §1.5), the horizon remaining (29.0 s normal / 10.7 s adversarial), and that
  the response is `scripts/gates/m23aw-prepare-headroom.mjs`, never a bigger
  `testPrepareTimeout`.

- **Leg C — THE REVIEW CADENCE.** `@MainActor`-isolated suite count ≤ **330**
  (measured 298). Explicitly labelled a cadence, not a physical threshold; §6.2
  states that `ds/dN` is unmeasured and that bumping this number **requires
  pasting a fresh gate campaign result into the file's comment**. Also PRINTS,
  and does not assert, the prepare-issuing site count (60) and the total suite
  count (486) so the trend is in every run's log.

**Leg D — the print-continuity pin** (belongs here because it is the same scan):
`Tests/DAWEngineTests/SoundBankHostingTests.swift` must still contain the exact
prefix `[measured] GM bank prepare-to-ready wall time`, and
`Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift` the exact prefix
`[measured] m19-e contended prepares`. **The gate in §5.3 parses both; a
reformat blinds it silently**, and several roadmap items read past measurements
off them. This makes the ADDITIVE-ONLY rule machine-enforced for the first time.

### 5.3 PART 3 — the headroom gate (node, run deliberately)

**New file:** `/Users/dsemenov/Views/daw-pro/scripts/gates/m23aw-prepare-headroom.mjs`

Precedent for the split: **m20-d.** No Swift test on this machine could
discriminate the m20-d edit — mutating it left the suite green, measured — so
the proof lives only in the live gates. Same shape here: no per-run Swift
assertion can hold this property without flaking (§2.5), so it moves to a gate.
Unlike the UI gates in that directory this one needs no staging app and never
touches port 17600 or 17695.

**What it does.**

1. Runs `./scripts/test.sh` **N = 5 times sequentially** (`--runs N` to override;
   `--from-logs <dir>` to re-score an existing campaign).
2. For each run: rejects the run if `grep -c '^✘'` > 0 (exit status is not
   evidence); parses `GM bank prepare-to-ready wall time`, the `m19-e` line's
   `max` and `horizon`, and the run's total wall time.
3. **CAMPAIGN VALIDITY (anti-contamination).** Median run wall time must be
   ≤ **120 s**. Measured: normal runs 93.4–101.3 s; the adversarial run 156.7 s.
   A campaign run on a busy machine is not a normal-population campaign, and
   this leg detects that from data the run already prints. Invalid → exit 2,
   distinct from a threshold failure.
4. **ANTI-CIRCUMVENTION.** The parsed `horizon` must be exactly `60.0 seconds`.
   If someone raises `testPrepareTimeout`, the margin would silently improve and
   the gate would go green on the forbidden move. This leg makes the gate refuse
   to be fixed that way. **This is the single most valuable leg in the design.**
5. **THE THRESHOLD.** Worst T1 across the campaign must be ≤ **36 s** (§6.1).
   Exit 1 with a message that states the margin, forbids raising the horizon,
   and names m23-aw-1 as the permitted response.
6. Prints the full campaign table in the two-population idiom, and prints — never
   asserts — the stress-`max` column, so the §1.3 comparison stays reproducible.

**One threshold, not two.** A "warn at 1.75× that exits 0" is documentation with
a shebang.

### 5.4 PART 4 — additive fields on the GM print

**File:** `/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/SoundBankHostingTests.swift:103`

```swift
print("[measured] GM bank prepare-to-ready wall time: \(prepareTime), "
      + "horizon \(AUHostRegistry.defaultPrepareTimeout), "
      + "margin \(marginString)")
```

**ADDITIVE ONLY** — the prefix and the first value keep their exact spelling and
position; m23-ab-3, m23-at, m23-aw and this document all read past measurements
off that prefix. `horizon` mirrors what m23-as-2 appended to the m19-e line and
makes the void-clause staleness class self-correcting: the record states the
timeout that actually applied. `margin` is `horizon / prepareTime` to three
decimals, printed and **never asserted** — it is the number a human should be
able to grep out of any log without arithmetic.

### 5.5 One home

`marginString` and the 36 s threshold must NOT both be spelled in Swift and in
JS. The threshold lives **only** in the gate (`HEADROOM_LIMIT_SECONDS`), because
only the gate has a population to apply it to. The Swift side owns only the
horizon constant, which already has one home
(`AUHostRegistry.testPrepareTimeout`) and is now pinned to it in both places.

---

## 6. Thresholds, derivations, and re-derivation rules

### 6.1 The gate's limit: worst-of-≥5 T1 ≤ 36 s

**Derivation, MEASURED, from the NORMAL population only (P1) with the adversarial
run used solely as a coefficient (§1.4):**

> The failure this item exists to prevent is an AU suite reddening with
> `"timed out after …"`. That happens when a prepare crosses the 60 s horizon.
> Measured adversarial inflation is **1.591×** (T1) / **1.582×** (stress max) —
> two independent channels agreeing. So the normal-population worst at which an
> ordinary loaded machine reaches the horizon is
> **60 / 1.591 = 37.71 s**. Round DOWN to **36 s** (1.048× safety on the
> coefficient).

Position today: worst-of-5 = 30.994 s, i.e. **1.162× of cushion and 16 % of
growth before the gate fires** — while the *actual* breakage is 94 % of growth
away. That is the lead time the item asked for, and it exists only because the
statistic is a worst-of-5 in a validity-checked campaign rather than a per-run
draw.

⚠️ **THE SAME NUMBER 36 IS REJECTED IN §2.5 AND ADOPTED HERE. The reconciliation
is POPULATION EXCLUSION, not variance.** §5.3's campaign-validity leg (median run
wall time ≤ 120 s) excludes the adversarial population *by construction*, so the
36 s limit is never evaluated against a 49.311 s draw. §2.5's rejection applies
to a per-run `#expect`, which has no such filter and therefore must survive every
observation the tree can produce. Same number, different admissible inputs.

⚠️ **ORDERING, and it is load-bearing: the 120 s VALIDITY LIMIT is what provides
the flake protection here, NOT the 1.162× cushion.** The derivation
`60 / 1.591` uses the adversarial coefficient to answer "at what normal-population
worst would a loaded machine break?", and the validity leg then guarantees the
limit is never scored under those conditions. The two constants are therefore a
PAIR: **loosening the validity limit (say to 150 s) silently converts the 36 s
threshold into a flake generator.** They are re-derived together or not at all —
a campaign-validity change without a threshold re-derivation is the same class of
edit as raising the horizon.

⚠️ **Why 1.162× is acceptable here and was not acceptable in §2.2.** Worst-of-5
has a *higher expectation* than a single draw but a *lower variance*; the cushion
is against campaign-to-campaign variance, not run-to-run variance. And a gate
failing costs one deliberate re-run and a human decision — it does not redden
`./scripts/test.sh`. The same number in a per-run `#expect` would have to absorb
the 1.591× load coefficient, which is what makes the interval empty.

**RE-DERIVATION RULE — follow it instead of inventing a fresh constant:**

> Re-measure T1 across **≥ 5 green FULL-SUITE runs** (the NORMAL population —
> never the adversarial one) plus **one** adversarial run under the m23-ab-2
> protocol. Recompute `adversarialInflation = adversarialT1 / worstNormalT1`,
> cross-check it against the same ratio on the m19-e `max` column, and set the
> limit to `floor(horizon / adversarialInflation)` rounded down to the nearest
> second. The limit must retain **≥ 1.10×** headroom over the worst normal
> observation. **If it cannot, STOP — do not lower the ratio and do not raise
> `testPrepareTimeout`.** That state means an ordinary loaded machine is inside
> one bad run of the horizon, and the only correct response is load reduction
> (m23-aw-1) or a roadmap-approved, argued change of horizon.

**Does the rule have a solution today? YES, and only just.** `60 / 1.591 =
37.71`; limit 36; `36 / 30.994 = 1.162 ≥ 1.10` ✓. **It expires at a normal-
population worst of 32.7 s — 5.5 % of growth away.** That is stated plainly
rather than hidden: the rule is designed to run out *soon*, because the honest
finding is that the margin has already been spent. When it runs out, it says so
legibly instead of silently, which is the property `min < 1.0` has and
`median < 8.0` did not.

### 6.2 Leg B's budget: 3 000 ms of deliberate main-actor spin

**Derivation:** the measured total today (§1.7), pinned where it stands. It is a
RATCHET, not a computed capacity — §1.5's coefficient (~0.5–0.9 s of prepare per
1 s of hog) is SUGGESTED from one perturbation and must not be used to compute a
budget to two significant figures.

**RE-DERIVATION RULE:**

> A new deliberate main-actor hog may be added, but the author must (1) add it to
> Leg A's table with its duration, (2) raise Leg B by exactly that duration, and
> (3) **run `scripts/gates/m23aw-prepare-headroom.mjs` and paste the campaign's
> worst T1 and margin into the comment above Leg B.** If the gate fails, the hog
> does not land. If a hog can be made conditional (`.enabled(if:)`) without
> losing what it proves, prefer that — `MainActorStarvationGateTests` and
> `OutputDeviceLoopbackGateTests` are the precedent, and it is why seven 1.5 s
> `Thread.sleep`s cost this horizon nothing.

### 6.3 Leg C's cadence: `@MainActor` suites ≤ 330

**NOT a physical threshold. `ds/dN` is UNMEASURED and §4.3 explains why it
cannot be measured from existing data.** 330 is 298 + ~10 %, which at the
measured 5.2 suites/day fires roughly weekly. Its only job is to force a
periodic re-measurement of a quantity that otherwise drifts silently — which is
the exact defect m23-aw was filed about. Bumping it carries the same obligation
as §6.2 step (3): paste a fresh gate result. **Raising it without running the
gate is the same act as raising the horizon, and the file must say so.**

---

## 7. Mutation discriminators — how a future author proves each pin can fire

*"A bound nobody has seen fire is a bound nobody has calibrated."*

### 7.1 Part 1 (the 60 s value pin)

Structural, so the discriminator is a temporary edit with a byte-exact revert:
set `testPrepareTimeout` to `.seconds(61)`, run
`./scripts/test.sh --filter AUPrepareTimeoutPolicy`, confirm **exactly one**
failure (`testTimeoutIsSixtySeconds`) and that `defaultDivergesUnderTest` stays
green — the failure must be *discrimination*, not collateral. Revert and
`git diff` must be empty. Record the observed failure text in the close-out.

### 7.2 Part 2 (the occupancy pin) — PERMANENT, no source edit required

**This is an improvement on the existing site tests and should not be dropped
for symmetry with them.** Factor the scanner as
`hogSites(in lines: [(number: Int, text: String)], file: String) -> [HogSite]`,
a pure function over text. Then ship a companion `@Test` that feeds it a literal
`[String]` fixture containing a third, synthetic hog and asserts:

- the scanner returns **3** sites for the fixture (Leg A's set equality would
  fail against the shipped table),
- the summed duration exceeds 3 000 ms (Leg B fires),
- and — the anti-vacuity leg — the same fixture with the synthetic hog wrapped
  in `.enabled(if:)` returns **2**, proving clause (e) is actually implemented
  and the pin is not simply counting the word `while`.

A permanent discriminator means the pin is re-validated on every run, not once
at authoring time.

### 7.3 Part 3 (the gate)

Underscore-prefixed fixtures in `scripts/gates/` are skipped as harness by the
corpus classifier, which is exactly what is wanted:

- `_m23aw-fixture-green.log` — five synthetic runs at 30.9 s, wall 97 s,
  `horizon 60.0 seconds`, no `✘` → gate must exit **0**.
- `_m23aw-fixture-slow.log` — one run at 45 s → gate must exit **1**, and the
  message must name 45.
- `_m23aw-fixture-raised-horizon.log` — 30.9 s but `horizon 90.0 seconds` →
  gate must exit **1** citing the anti-circumvention leg, **not** the threshold.
  Without this fixture the most valuable leg is the least tested one.
- `_m23aw-fixture-loaded.log` — 30.9 s, wall 160 s → gate must exit **2**
  (campaign invalid), distinct from 1.
- `_m23aw-fixture-red-run.log` — contains a `^✘` line → gate must refuse the
  campaign rather than score it.

Run all five through `--from-logs` in CI-less fashion (`node
scripts/gates/m23aw-prepare-headroom.mjs --selftest`) and record the five exit
codes in the close-out. ⚠️ **The two exit-1 cases must be discriminated by
MESSAGE, not only by code.** If `_m23aw-fixture-raised-horizon.log` fails for the
*threshold* reason rather than the *horizon* reason, the leg this design calls
its most valuable is silently uncalibrated and the self-test would not notice —
so `--selftest` must assert on the failing leg's identifier, not just on
`exitCode === 1`. **Do not report the gate as working on the strength of
one green campaign** — a gate that has only ever passed has only ever been
observed not to run.

### 7.4 The negative control that matters most

When the gate is first run for real, its campaign must be green *and* its
recorded worst must land inside 29.287–30.994 s. A campaign outside that band on
an unmodified tree means the machine, not the tree, moved, and the numbers in
this document must be re-taken before anything is derived from them.

---

## 8. Implementation plan

Order matters: the gate must exist before the pins cite it, and the print must
be extended before the gate parses it.

1. **`/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/SoundBankHostingTests.swift`**
   — extend the `:103` print ADDITIVELY with `horizon` and `margin` (§5.4).
   Touch nothing else in T1; in particular leave `#require(status == .ready)` at
   `:151` exactly as it is — it is the hard bound and it is correct.
   *Verify:* `./scripts/test.sh --filter SoundBankHosting`, and grep the new
   line for the unchanged prefix.
2. **`/Users/dsemenov/Views/daw-pro/scripts/gates/m23aw-prepare-headroom.mjs`**
   — the gate (§5.3), with `--runs`, `--from-logs`, `--selftest`. Threshold and
   validity limits as named constants at the top with the §6.1 derivation in the
   header comment.
   *Verify:* `--selftest` against the five fixtures of §7.3; then one real
   5-run campaign (~9 minutes, run backgrounded).
3. **`/Users/dsemenov/Views/daw-pro/scripts/gates/_m23aw-fixture-*.log`** — the
   five fixtures (§7.3). Underscore prefix is required: it is what keeps them
   out of the gate corpus census.
4. **`/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/MainActorOccupancySiteTests.swift`**
   — new suite, four legs plus the permanent discriminator (§5.2, §7.2).
   *Verify:* `./scripts/test.sh --filter MainActorOccupancy`; confirm the
   printed `[measured]` set is exactly the two sites of §1.7.
5. **`/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/AUPrepareTimeoutPolicyTests.swift`**
   — delete `testTimeoutHasHeadroomOverMeasuredWorstCase`; add
   `testTimeoutIsSixtySeconds` with the measurement-bearing doc comment (§5.1).
   *Verify:* the discriminator of §7.1.
6. **`/Users/dsemenov/Views/daw-pro/Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift`**
   — comment-only. The open flag at `:458-465` currently says max reached
   27.33 s (46 %) full-suite; append (do not rewrite) that m23-aw measured the
   **T1** channel at 30.994 s / 51.7 % normal and 49.311 s / 82.2 % adversarial,
   that the m19-e `max` column did **not** move over the same interval, and that
   the resolution is the gate. **Do not touch the `[measured]` print or either
   shipped `#expect`.**
7. **`/Users/dsemenov/Views/daw-pro/docs/research/design-m23as2-prepare-estimator.md`**
   — correct §5.6's factual error in place (§2.1 item 4), in the idiom that file
   already uses for orchestrator corrections (an indented `> ⚠️ CORRECTED …`
   block), keeping the conclusion and replacing the reason.
8. **`/Users/dsemenov/Views/daw-pro/docs/ARCHITECTURE.md`** — new "Key future
   decisions" entry (§12).
9. **`/Users/dsemenov/Views/daw-pro/docs/ROADMAP.md`** — tick m23-aw with the
   close record; file m23-aw-1 and m23-aw-2 (§11).
10. **`/Users/dsemenov/Views/daw-pro/CHANGELOG.md`** — one entry.

**Wire surface: ZERO new commands.** allCommands / MCP / catalog stay
**171 / 174 / 74**. Nothing here is user-facing; the whole item lives in the test
and gate tiers. (Stated explicitly because the project's default is that every
capability ships a control command + MCP tool + test — this is not a capability.)

**Test-count delta, expected:** +1 suite (`MainActorOccupancySiteTests`), **+4
or +5 tests** (Legs A–C plus the permanent discriminator, and Leg D either as its
own `@Test` or folded into Leg A's scan — both are correct implementations),
−1 test (the deleted tautology) +1 test (the 60 s pin) = **4712 → 4716 or 4717
tests, 486 → 487 suites**. An implementer who lands a delta outside that pair
must explain it rather than update the baseline.

**Verification protocol for the close-out:** full suite backgrounded (~95–100 s),
`grep -c '^✘'` must be 0, and the printed `Test run with N tests in M suites`
must be quoted. `./scripts/test.sh` exits 0 on failure; the exit status is not
evidence. `swift build` does **not** compile test targets — any zero-warning
claim must come from `swift build --build-tests`.

---

## 9. Failure modes of the design itself

- **The gate is never run.** Its threshold then measures nothing, exactly like
  the literal it replaces. Mitigation: Legs B and C of the Swift pin can only be
  bumped by pasting a fresh gate result, so every growth event routes through
  it. This is the design's weakest joint and it is stated, not hidden.
- **Leg C fires weekly and gets bumped thoughtlessly.** Mitigation: it is
  labelled a cadence, its bump ritual is one line, and the number it protects
  (the horizon) is pinned separately in two places, so a careless bump of Leg C
  cannot reach the horizon.
- **The occupancy rule under-enumerates.** §1.7 lists three `usleep` sites whose
  main-actor isolation is UNPROVEN. If they are in fact main-isolated the ledger
  is missing 0.2 s. Mitigation: §7.2's clause-(e) anti-vacuity leg proves the
  scanner implements its rule; §10 states the residual honestly; m23-aw-2 owns
  the resolution.
- **The machine changes.** Every number here is this machine's. A new machine
  invalidates the 1.591× coefficient, the 36 s limit and the 120 s validity
  limit together. Mitigation: the gate's validity leg fires first and loudly on
  a materially different machine, and §6.1's rule is written to be re-run rather
  than reinterpreted.
- **Someone answers a gate failure by raising the horizon.** Mitigation: §5.1's
  Swift pin and §5.3's `horizon` leg both fail, in different tools, and both say
  why in the failure text.

---

## 10. What this design does NOT prove

Stated plainly, because several of these read like they were established above
and were not.

1. **It does not prove the cause of the 26.9 → 30.994 rise.** The wedge hog is a
   measured *partial* contributor (mean +1.773 s, worst-to-worst +1.071 s,
   overlapping populations). The residual — P2's worst 29.923 s still exceeding
   m23-at's 24.3–26.9 band — is **not separable from day-to-day machine
   variation** with n = 6 (m23-at, another day) against n = 5 (here). No claim of
   attribution is made.
2. **It does not measure a seconds-per-suite slope, and no number in it should
   be read as one.** Leg C is a cadence.
3. **It does not measure the queue-depth amplification `α`** that
   `design-m23as2-prepare-estimator.md` §4.2 marks REASONED. §1.5's ~0.5–0.9
   coefficient is SUGGESTED from a single perturbation of a single hog and does
   not carry to two significant figures.
4. **It does not establish that T1's prepare is or is not the process's first
   `.soundBank` prepare** (a cold DLS bank load versus the warm process-global
   cache the m23-as-2 control leg measures at 0.012–0.043 s). If T1 is
   bimodal on suite ordering, the 1.058× spread understates the channel. Nothing
   in the campaign settles this; it is filed as m23-aw-2.
5. **It does not prove the occupancy population is complete** — §1.7 clause (d)
   is unproven for `RecoveryAnchorContinuityGateTests.swift:285/286/307`.
6. **n = 1 for the adversarial population.** The 1.591× coefficient rests on one
   run per channel; its credibility comes from the two channels agreeing
   (1.591 / 1.582), not from replication.
7. **It proves nothing about production.** The shipped horizon is 10 s and a
   real prepare on an idle machine is 0.05–0.6 s. Every number here describes a
   test harness, and no part of this design changes what a user experiences.
8. **It does not close the Surge XT wedge** (m23-av route (b), out-of-process
   AUv3, needs full Xcode). Nothing here shortens a wedge by a millisecond.

---

## 11. Follow-up items to file

- **m23-aw-1 — REDUCE THE HARNESS'S MAIN-ACTOR LOAD. This is the only permitted
  response to the broken 2× discipline.** Levers, in measured order: (i) make
  the deliberate hogs conditional where they can be, following
  `MainActorStarvationGateTests`' `.enabled(if:)` precedent — seven 1.5 s
  `Thread.sleep`s already cost this horizon nothing that way; (ii) the two-pass
  AU test split (§4.7), **with the contention trade adjudicated first** — the
  m18-d/m19-e race only reproduces under load, so halving the load weakens the
  gate that guards a process-corrupting DLS race; (iii) re-examine whether
  `SoundBankHostingTests` needs a full `OfflineRenderer.prepareAudioUnits` in T1
  at all. **Do not open this item by raising `testPrepareTimeout`.**
- **m23-aw-2 — CHARACTERISE THE T1 CHANNEL.** Three unknowns from §10: is T1's
  prepare the process's first `.soundBank` prepare (cold vs warm bank), is the
  m23-at → today residual real growth or machine variation (re-run m23-at's own
  protocol on today's tree), and are the three `RecoveryAnchorContinuityGate-
  Tests` `usleep` sites main-actor-isolated. Each is a measurement, not a fix.
- **m23-aw-3 (optional) — widen the occupancy ledger to `Sources/`.** Nothing in
  `Sources/DAWEngine` should hold the main actor for a fixed duration; a pin
  proving that is cheap once §5.2's scanner exists.

---

## 12. `docs/ARCHITECTURE.md` — "Key future decisions" entry

Add, in the section's established style:

> **AU-prepare headroom under test-harness load: SETTLED BY DESIGN (m23-aw,
> 2026-08-03; design `docs/research/design-m23aw-headroom-tripwire.md`).** The
> test-time prepare horizon (`AUHostRegistry.testPrepareTimeout`, 60 s) is
> watched by a **structural pin in the suite and a statistical gate outside
> it** — never by a per-run wall-clock bound. **The finding that forced the
> split, MEASURED: m23-at's stated 2× headroom discipline is already violated.
> The worst GM prepare across five green full-suite runs is 30.994 s (margin
> 1.936×, 51.7 % of the horizon) and the same channel reaches 49.311 s — 82 % of
> the horizon — under ordinary machine load, while `AUPrepareTimeoutPolicy-
> Tests:68` asserted `60 >= 2 × 27` from two compile-time constants and passed.**
> A prepare's wall time here is ~99.98 % main-actor/`dlsBankQueue` queueing, so
> it is a measurement of the harness, not of the AU — which is precisely why it
> is the right quantity for this question and the wrong quantity to assert
> per-run: the channel inflates **1.591×** under load (cross-checked at 1.582×
> on the independent m19-e `max` column), so every threshold that leaves usable
> lead time is below a value a green tree already produces. **Rejected: the
> item's own prescription, `prepareTime <= 0.6 × horizon`** — 36 s carries 1.162×
> over the normal worst and is RED by 37 % against a measured green adversarial
> run, worse than the 1.73× that got `median < 8.0` deleted one item earlier,
> and it would have been GREEN today while the discipline it encodes was already
> broken. **Rejected: a subtractive same-run instrument** — m23-as-2's
> additive-noise rule presumes the contaminant is not the quantity of interest,
> and here the queue *is* the signal, so cancelling it cancels the finding.
> **Rejected: a suite-count threshold** — the seconds-per-suite slope is
> unmeasured and unmeasurable from existing data (three confounds: the m23-at
> policy regime, an occupancy change, and uncommitted growth). **Rejected, and
> now actively guarded: raising the horizon** — the forbidden move breaks
> `AUPrepareTimeoutPolicyTests.testTimeoutIsSixtySeconds` and independently
> fails the gate's `horizon` leg, which refuses any campaign not run against
> 60 s. What ships: a set-equality pin on **deliberate main-actor occupancy**
> (2 sites / 3 000 ms measured, one of them added the same day and costing
> ~1.8 s of the horizon), a print-continuity pin making the ADDITIVE-ONLY rule
> machine-enforced, and `scripts/gates/m23aw-prepare-headroom.mjs` (worst-of-5,
> campaign-validity-checked, limit 36 s derived as `horizon / 1.591`). **NOT
> settled here: whether the harness's main-actor load should be reduced, and
> how** (m23-aw-1) — the only permitted response when the gate fires, and it
> trades against the fact that the m18-d/m19-e DLS race only reproduces under
> the very contention that would be removed.
