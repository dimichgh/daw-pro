# m23-as — timing/probe anti-pattern audit

INVENTORY ONLY. No test file was edited to produce this document. Scope,
method, and the two anti-patterns are per the m23-as brief (ROADMAP.md:795),
which this document follows where it differs from the item's original filing
text — the item predates three suites (`MainActorStarvationGateTests`,
`StarvationWitness`, and the m23-bq/bs/bt recovery-timing family) that already
implement the fix shape the item asks for.

## Method

Enumerated every site that **takes a clock reading** (`ContinuousClock`,
`SuspendingClock`, `.measure(`, `DispatchTime.now`, `mach_absolute_time`,
`CFAbsoluteTimeGetCurrent`, `ProcessInfo.processInfo.systemUptime`, `Date()`,
`.timeIntervalSince`), not assertion text — grepping `#expect(...duration...)`
is the wrong axis (see "Landmines," item 4). The candidate set was handed over
as 70 files
(`/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/73c8163a-27b5-48fc-94b9-8e63836c64d7/scratchpad/as-candidates.txt`).
Every one of the 70 is accounted for below, with a verdict.

**Completeness re-check, independent of the handed-over list.** Re-derived the
candidate set from scratch with a wider spelling set than the brief's own list
— adding `Date.now` (the idiomatic Swift 6 spelling `Date()` is often
refactored to), `DispatchWallTime.now`, `CACurrentMediaTime`, and
`clock_gettime`, none of which were in the original enumeration — and diffed
against the 70:

The actual one-liner run (scope **`Tests/` only** — narrower than §0's sweep,
which is `Tests/ Sources/`, since this check is about test-site completeness,
not the production `DeadlineRace` primitive itself):

```
grep -rlE 'ContinuousClock|SuspendingClock|DispatchTime\.now|DispatchWallTime\.now|mach_absolute_time|CFAbsoluteTimeGetCurrent|CACurrentMediaTime|clock_gettime|systemUptime|Date\(\)|Date\.now|\.timeIntervalSince|clock\.measure|Clock\(\)\.measure' Tests/ | sort > actual.txt
comm -23 actual.txt claimed.txt   # claimed.txt = the sorted 70-file candidate list
```

Result: **empty — zero files outside the 70 contain a clock-reading spelling
under this wider pattern.** The reverse diff (candidate-only entries) returns
27 files, all already accounted for in §2 as deterministic/fixture-only/
`.measure(`-false-positive/zero-hit groups — i.e. the 70-file list is a
superset of what a stricter pattern finds, not a subset that missed something.
This converts "every site found" from an inherited claim into one checked
against an independently re-derived pattern, including the four spellings most
likely to slip through a narrower one. (§5's first bullet makes a related
completeness claim from a different derivation; this check is the one that
specifically targets the `Date.now`/`DispatchWallTime.now`/`CACurrentMediaTime`/
`clock_gettime` spellings, so the two are complementary, not a duplicate.)

Audio/musical durations (`durationSeconds`, RMS windows, beat maths) and
constant-vs-constant pins (`AUPrepareTimeoutPolicyTests:39`) are out of scope
and are not double-counted here even where they happen to sit beside a
genuine clock read in the same file.

## 0. Re-verified finding: the process-global-counter sweep (anti-pattern b)

Re-ran the orchestrator's widened pattern in one command:

```
grep -rnE 'malloc_zone_statistics|blocks_in_use|getrusage|proc_pid_rusage|malloc_default_zone|os_proc_available_memory|physicalMemory|host_statistics|vm_statistics|task_info|mach_task_basic_info|activeProcessorCount' Tests/ Sources/
```

Result: **6 hits, all comments**, all in
`Tests/DAWEngineTests/InsertSpectrumTapTests.swift` (lines 34/37/53/70) and
`Tests/DAWEngineTests/InsertSpectrumChainTests.swift` (line 41), describing
the `malloc_zone_statistics(...).blocks_in_use` probe m23-ab-2 removed and the
thread-filtered `malloc_logger` probe that replaced it. **No live
process-global probe exists in the tree.** Anti-pattern (b) is confirmed
swept to zero; nothing new to convert here.

## 1. Anti-pattern (a) sweep — verdict by file

### 1.1 Genuine sites with live wall-clock reads — full triage

These are the files that actually measure elapsed wall time and assert on it,
or that carry the item's own pre-triaged calibration exemplars. Trivial files
(no timing assertion) are grouped compactly in §1.2.

---

**`Tests/DAWCoreTests/DeadlineRaceTests.swift`** (m23-at) — MIXED verdict,
four legs:

- **Leg 1, primary** (`timeoutFiresWhileMainActorIsHogged`, line 176,
  `#expect(m.timedOut, ...)` for every arming completing inside the recorded
  hog window) — **JUSTIFIED IN PLACE.** Fully relative and self-validating:
  an arming counts only if it finished strictly inside a directly-observed
  hog window, so a main-actor-bound deadline cannot produce even one passing
  sample. No wall-clock constant is compared.
- **Leg 1, secondary** (line 197, `#expect(median <= Self.seconds(medianCeiling))`,
  `medianCeiling = .milliseconds(600)` against a hardcoded `budget =
  .milliseconds(200)`) — **CONVERTED-CANDIDATE** (given by the brief,
  confirmed by reading the file). Currently asserts an absolute median wall
  time. Should assert a ratio against a same-process, same-run calibration —
  the same shape `EQCurveEditorModelTests.swift` already ships (§1.1, below).
  Note for the record: **m23-at shipped this ceiling in the same cycle m23-as
  was filed to prevent it** — the anti-pattern was reintroduced after the
  item existed.
  **Sharper structural point, confirmed by reading the control flow (lines
  164–197), not just the ceiling's history:** the sample-size guard
  `try #require(elapsedInsideWindow.count >= requiredArmings, ...)` (line 191)
  runs *before* the median is computed (line 196) or asserted (line 197). In
  the pre-m23-at, main-actor-bound shape, a hogged deadline cannot resolve
  *inside* the hog window at all — it can only resolve after the actor frees
  up, which is exactly the `m.end < spinEnd` discard branch (lines 167–173,
  "discard rather than assert"). So a regression of the exact kind this file
  exists to catch would starve `elapsedInsideWindow` toward zero and fail the
  line-191 `#require` — never reach line 197. **The median ceiling's
  discriminating power has not been exercised even out-of-band by this file's
  own control flow; the only leg that has ever demonstrably caught the
  main-actor-bound defect is leg 1's primary assertion (line 176) and the
  sample-size precondition, not the absolute median bound.** This corroborates
  the CONVERTED-CANDIDATE verdict on the mechanism, not just the style: the
  600 ms ceiling is not a bad shape guarding against nothing — it is still
  live against the regime its own failure message names (a deadline that
  correctly avoids the main actor but runs slower than its budget) — but it
  has never been shown to be the thing that catches a main-actor-bound
  regression, and by this control-flow reading it structurally cannot be.
- **Leg 2** (`uncontendedWorkReturnsItsValue`, `.seconds(60)` budget) — **not
  actually a clock-reading site**: the test passes `60s` as a *policy value*
  into `DeadlineRace.run` and asserts only the *outcome type* (`.value` vs
  `.timedOut`), never an elapsed duration. The in-source comment ("carries NO
  claim... just has to be larger than the main-actor starvation this suite's
  siblings produce... measured at 5 s it failed 5/20 iterations inside a full
  parallel run, and those failures were CORRECT") **holds** — it is
  corroborated by measurement, and there is nothing for a ratio to replace
  because no duration is read or compared. JUSTIFIED IN PLACE.
- **Leg 3** (`concurrentResumersNeverDoubleResume`, `.milliseconds(50)`
  budget) — same shape: no elapsed time is read; the assertion is
  `valued + timedOut == 100`, a count. The 50/40/60 ms numbers are inputs to
  the mechanism under test (a double-resume race), not a timing bound. The
  split itself is explicitly NOT asserted on. JUSTIFIED IN PLACE.
- **Leg 4** (`thrownWorkSurfacesAsError`, `.seconds(60)` budget) — same: no
  clock read, asserts only that the outcome is `.error`. JUSTIFIED IN PLACE.

---

**`Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift`** (m23-bs-2)
— **JUSTIFIED IN PLACE**, confirmed reading the whole file (680 lines):

- The pre-triaged site (line 641, `#expect(elapsed > headSeconds, ...)`) is a
  precondition guard, not a timing bound: `headSeconds` is derived from beat
  geometry computed in the same run, with a self-explaining "Lengthen rollMs"
  failure message. Confirmed.
- Every other assertion in the file (`residue <= continuityEpsilonBeats`,
  `residue <= overrunBeats + epsilon`, `horizonSeconds ==
  StartAnchorBudget.continuationHorizonSeconds(...)`, `playerCount ==
  snapshotCount`, `clampDownCount == 0`) compares two independently-derived
  quantities to each other or to a formula's own read-back — never a
  wall-clock duration to a guessed ceiling. `continuityEpsilonBeats = 1e-12`
  is a **derived float tolerance** (documented ULP analysis, not a guessed
  millisecond bound) — the file's own doc comment explicitly warns against
  applying the "tighten to measured-worst × 10" rule literally here because
  it would produce a zero epsilon.
- `measureRenderClockLeadSeconds()` uses `Date().addingTimeInterval(1.0)` as
  a **bounded poll deadline** waiting for the first render callback (never
  asserted) — precondition wait, not a timing assertion.
- `mach_absolute_time()` / `AVAudioTime.seconds(forHostTime:)` reads feed a
  printed, never-asserted cross-check (δ vs `buffer + latency`).

---

**`Tests/DAWEngineTests/RecoveryPlayheadTests.swift`** (m23-bq/m23-bs-2) —
**JUSTIFIED IN PLACE, with a disclosed landmine.**

Two hardcoded ceilings exist: `maxLagBeats = 0.25` (line 251) and
`maxDeltaBeats = 0.10` (line 279). Both are **lag metrics**
(`expected-wall-time-implied-beat − pushed-beat`), not raw elapsed-duration
measurements, and the file implements exactly the doctrine
`docs/ARCHITECTURE.md`'s m23-bu-1 entry settled on: *"starvation costs this
metric sample COUNT, never sample ACCURACY"* — because the beat and its
timestamp are read in the same synchronous main-actor tick, a late-firing
sample is late but not wrong. This is corroboration for the real regression
guard (the property assertion in `RecoveryAnchorContinuityGateTests`), by the
file's own explicit design (§9.2): *"if it flakes under full-suite load,
loosen the TIMING leg, never the property assertion."* Both ceilings are
derived from measurement (0.25 = "largest round number below the unfixed
tree's recover-only 0.268"; 0.10 from a measured β·δ band) and a discriminating
mutant was run (`renderClockTrusted: true` → lag 2.6+ beats, filtered/unstarved)
proving the ceilings have teeth.

**Landmine, self-disclosed in source but worth surfacing here**: these
ceilings are **buffer-size dependent through δ**, not suite-load dependent.
The file's own header states plainly: *"AT 2048 FRAMES THIS FILE FLAKES ON A
CORRECT ENGINE"* and gives the re-derivation formula
(`(control + β·δ_max) × 1.5`). This is a different axis of fragility than the
item's stated anti-pattern (suite contention) — it is a **hardware-config**
landmine, disclosed and with a documented remedy, not an unconverted
suite-load flake. Not counted as a CONVERTED-CANDIDATE because it is not the
anti-pattern in question, but flagged under "Landmines" below since nobody
should discover it by having a 2048-frame device.

---

**`Tests/DAWEngineTests/RecoveryCostSplitTests.swift`** (m23-bs-1) —
**JUSTIFIED IN PLACE**, by explicit design. The file's own header states:
*"⚠️ NO TIMING ASSERTION — BY DESIGN (m23-bu-1's rule)... The playhead-lag
cross-check is PRINTED and never `#expect`ed."* Every `#expect` in the file
(`segmentB > 0`, `lead >= 0.06`, `segmentB == initialSegmentB`,
`restartsAfter == restartsBefore + 1`, `lead > 0.0601` anti-vacuity) is a
property or a comparison against the engine's own documented floor constant
(`StartAnchorBudget`'s 0.06 s floor), never a guessed wall-clock ceiling.
`Date()` readings exist only to feed the printed, never-asserted
`measuredStep`/`residual`/`median lag` diagnostics. This file is env-gated
off by default (`DAWPRO_M23BS_COSTSPLIT=1`) for an unrelated reason (live
output-device contention budget), not because of timing fragility.

---

**`Tests/DAWEngineTests/EngineRebuildTests.swift`** (m23-bu-3) — **JUSTIFIED
IN PLACE.** The one live timing-shaped assertion is a **lag-GROWTH** metric
(`maxLag − minLag` across post-mark samples, ceiling `maxLagGrowthBeats =
0.5`), explicitly chosen over an absolute-lag or count metric because growth
cancels any constant per-run offset. The ceiling is derived (not measured):
anchor plateau bound (`StartAnchorBudget.continuationHorizonSeconds` ≈
0.18 beats at this fixture's n) + one buffer quantum of jitter (0.085 beats)
≈ 0.265 beats derived, with measured worst 0.087 beats isolated — 5.7× margin.
`StarvationWitness` classification guards the sparse-sample case.

---

**`Tests/DAWEngineTests/EngineWatchdogTests.swift`** (m23-bq, pre-bs-2 vintage)
— **JUSTIFIED IN PLACE, with a maintenance landmine.** Line 417:
`#expect(maxLag <= 1.2, ...)` — the same lag-against-wall-time shape as
`RecoveryPlayheadTests` (same "beat and timestamp read in the same
synchronous tick" reasoning applies), guarded by the same `StarvationWitness`
discriminator for sparse/dead-render cases. **Landmine**: this is a **stale
duplicate**. `RecoveryPlayheadTests`' own header explains its ceiling used to
be `1.2` "UNTIL m23-bs-2," when the anchor-lead defect that justified the
looser number was fixed and the sibling file's ceiling was retightened to
`0.25`. This file's `1.2` was **never retightened** — it is not wrong (still
immune to suite-load per the shared doctrine, and the mutant that trips
`RecoveryPlayheadTests`' 0.25 — `renderClockTrusted: true` → 2.6+ beats — would
trip this 1.2 too) but it is a second, looser, unmaintained copy of the same
regression guard. A future author retightening `RecoveryPlayheadTests` again
(e.g. for a buffer-size change) has no reason to know this file needs the
same edit.

---

**`Tests/DAWEngineTests/GaplessLoopTransportTests.swift`** — **JUSTIFIED IN
PLACE.** `ContinuousClock.now.advanced(by: .seconds(10))` (line 487) is a
generous bounded-poll deadline waiting for a witness push, never asserted —
explicitly "an OPTIMIZATION only," per the in-source comment, with the real
regression guard being the property `maxPush <= 1.0` (a loop-bound property,
not a duration).

---

**`Tests/DAWEngineTests/MainActorStarvationGateTests.swift`** (m23-bu-1) and
**`Tests/DAWEngineTests/StarvationWitness.swift`** (m23-bu-2) — **JUSTIFIED IN
PLACE — these ARE the reference exemplars**, per the brief. All live
measurement in `MainActorStarvationGateTests` is `.enabled(if:)`-gated behind
opt-in env vars and off by default; the one unconditional assertion
(`main.fired > 0 && nonisolated.fired > 0`) is a liveness sanity check on the
rig itself, not a timing bound. `StarvationWitness`'s own tests are headless
contract pins with no clock at all (`classify(mainActorSampleCount:
callbackCountBefore: callbackCountAfter:)`), pinning the render-callback-count
discriminator's arithmetic.

---

**`Tests/DAWAppKitTests/EQCurveEditorModelTests.swift`** (m23-ab-2) —
**JUSTIFIED IN PLACE — this is where the item's own cited model,
`recomputeRegressionTripsCalibratedBudget`, actually lives** (line 882). The
file documents the full conversion this whole audit is measuring against:
the pre-m23-ab-2 shape (`#expect(best < .milliseconds(1))`) is retired and
replaced with a ratio (`recompute/calibration`, K = 2.5) against a
same-process, same-run CPU-bound calibration (`calibrationWork`, deliberately
unrelated math so a real EQ-geometry regression still moves the ratio). The
K derivation is measured across isolated / full-suite / 20-process-adversarial
conditions (ceiling ≈ 1.19, K = 2.5, ≈2.1× margin), and
`recomputeRegressionTripsCalibratedBudget` proves the budget actually trips
on a synthetic 8× regression (4× was tried and rejected on measurement: too
close to the adversarial-load ceiling). Nothing to convert; this is the
target shape.

---

**`Tests/DAWEngineTests/RecoveryOutputPinGateTests.swift`** (m23-bt) —
**JUSTIFIED IN PLACE.** `Date()` is used only inside a bounded
poll-with-timeout helper (`waitUntil`, 3 s budget) whose `waitedMs` return
value is folded into a print-only diagnostic message, never asserted. Every
real assertion in the file is a property witness (`restarts`,
`outputPinReapplyCountForTesting`, `outputNodeRenderSampleTimeForTesting`,
`auhalDevice` identity) — the file's own header explains at length why a
green pin read-back is not proof by itself and why three independent,
non-timing witnesses are needed instead.

---

**`Tests/AIServicesTests/WhisperModelInstallCoordinatorTests.swift`** and
**`Tests/DAWControlTests/SpeechModelInstallCommandTests.swift`** — **JUSTIFIED
IN PLACE.** `DispatchTime.now()` is used only as a bounded poll-loop deadline
(2 s) waiting for an async status to change; never asserted on.

**`Tests/DAWEngineTests/LiveEventRingTests.swift`** — **JUSTIFIED IN PLACE.**
`ContinuousClock.now + .seconds(20)` is a generous poll-loop deadline draining
a ring buffer; the assertion inside the loop (`event.hostTime == received`) is
a property, not a duration.

---

### 1.2 New CONVERTED-CANDIDATEs found by this sweep (not previously filed)

**`Tests/DAWEngineTests/AudioContentAnalyzerTests.swift:677`**
(`performanceFiveMinutes`, m21-e §7) —
```swift
let clock = ContinuousClock()
let elapsed = try clock.measure {
    analysis = try AudioContentAnalyzer.analyze(fileAt: wav, ...)
}
let seconds = ... // Duration -> Double
#expect(seconds <= 5.0)
```
**CONVERTED-CANDIDATE.** A raw measured wall-clock duration (analyzing a
synthesized 5-minute WAV) compared directly to a hardcoded absolute constant
(spec §7's "5 s hard" bar). The suite is `.serialized` for an unrelated
reason (shared disk I/O with sibling cache tests) — it is **not** isolated
from full-suite CPU contention, so this is exposed to exactly the load
sensitivity `EQCurveEditorModelTests` was fixed for. **Should assert**: a
ratio of `AudioContentAnalyzer.analyze`'s wall time against a same-process,
same-run CPU calibration (same shape as `recomputeStaysWithinCalibratedBudget`),
or at minimum keep the constant but add a discriminator proving it can trip
(see NO-MUTATION-DISCRIMINATOR below — currently nothing shows this ever
reddens on a real regression). **Currently asserts**: `analyze()` on 300 s of
audio completes in ≤ 5.0 s wall time, absolute. **Should assert**: `analyze
wall time / calibration wall time < K`, K derived from measured spread.

**`Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift:229-230`**
(`prepareRenegotiationTeardownStress`, m19-e) —
```swift
#expect(minSeconds < 1.0)
#expect(median < 8.0)
```
**CONVERTED-CANDIDATE** (both lines). `prepareDurations` is a real
`ContinuousClock().measure` sample set collected from AU prepares under
deliberate concurrent contention (renegotiation churn + teardown races), and
this suite is **not** `.serialized` — it runs alongside the rest of the full
suite. The in-source comment for `median < 8.0` argues it is "≈4× the worst
measured median" and explicitly declines to assert on `maxSeconds` because
"absolute max is scheduling noise" — the authors already recognized the
load-sensitivity risk for the max channel but kept two other absolute
channels (min, median) anyway. **Currently asserts**: the least-contended
prepare completes under 1.0 s wall time, and the median of ~30+ samples stays
under 8.0 s. **Should assert**: both as ratios against a same-run CPU
calibration, following the `EQCurveEditorModelTests` K-derivation pattern —
or, if the intent is genuinely "this must stay far below the 10 s
`testPrepareTimeout` horizon" (a cross-check against another absolute in this
same tree, `AUHostRegistry.testPrepareTimeout`), assert the ratio to *that*
named constant rather than a second independently-guessed number.

> ⚠️ **CORRECTED BY MEASUREMENT — READ §6 BEFORE THIS PARAGRAPH.** The
> paragraph below is left as written for the audit trail, but its central
> claim is wrong. It compares a WORST-CASE single-prepare figure to a MEDIAN
> bound. §6 measures this suite's actual distribution three times and the
> median is 2.45–3.15 s, not 20–27 s. The exposure is real but far smaller
> than stated: margin 4× → 2.5×, not "3× below".

**This is not just fragile-in-principle — the 8.0 s calibration is against a
regime the tree has since left, on evidence in `ROADMAP.md:798` and `:796`
(both read directly, not recalled).** `ROADMAP.md:798` (m23-at's close-out)
records the GM sound-bank prepare path rising from 17–22 s pre-policy to
**24.3–26.9 s post-policy** (n=6), because a prepare that used to be abandoned
at the old 10 s timeout now runs to completion and lengthens the main-actor
queue everything else waits in. `ROADMAP.md:796` (m23-as-2, filed against this
same file) separately notes this suite's own in-source comment already
concedes "under the 300-suite parallel run a prepare measured 14 s wall with
every `.ready` green." A `median < 8.0` ceiling calibrated as "≈4× the worst
measured median" in an earlier, faster regime is now roughly 3× *below* a
measured 24–27 s regime the codebase itself documents elsewhere — this is the
strongest evidence in this document that the exposure is not theoretical.

**`Tests/DAWEngineTests/MIDIControllerInstrumentTests.swift:439`**
(`hostedAUScheduleCostRider`, the b2 rider) —
```swift
let perEventMicroseconds = max(0, denseNs - emptyNs) / 512.0 / 1_000.0
// Sanity envelope only — the number itself is the rider deliverable.
#expect(perEventMicroseconds < 100)
```
**CONVERTED-CANDIDATE** (weaker instance — flagged honestly as such). This
already does a same-process, same-run **subtraction** (dense-block minus
empty-block, best-of-5 each) rather than a bare absolute read, which
partially cancels ambient load — but a subtraction is not immune to
contention the way a ratio is: if the machine slows the "dense" call
proportionally more than the "empty" call under scheduling pressure (a
plausible asymmetry — the dense call does 512× more work per quantum), the
difference does not cancel it. The comment concedes the number is a "sanity
envelope only," i.e. the authors already knew this isn't load-bearing
precision. **Currently asserts**: absolute per-event cost < 100 µs.
**Should assert**: either the same subtraction against a ratio-based
threshold, or accept it as documentation and remove the `#expect` (the
comment already says the printed number, not the assertion, is "the rider
deliverable").

**`Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift:1061`**
(`armedInsertCostPerQuantum`, m23-r2b design §Q4) —
```swift
let delta = measured.a - measured.b   // ns/quantum, armed minus disarmed control
#expect(delta <= 3_000, "an armed insert costs \(delta) ns/quantum ...")
```
**CONVERTED-CANDIDATE** (borderline — this is the most defensible of the
four, and closest to already being the right shape). Unlike the other three,
this already interleaves A/B windows in the same run and takes the min per
side specifically to survive ambient load ("a machine that gets busier
mid-test [is not] charged entirely to whichever side ran second" — the
file's own comment). It has an explicit ~15× margin over the design target
and an anti-vacuity check (`tap.framesWritten`). Still, `3_000` is an
absolute nanosecond constant, and a *difference* of two same-run
measurements is a weaker guarantee than a *ratio* against an unrelated
same-run calibration — a proportional (not additive) slowdown under
contention is not fully cancelled by subtraction. **Currently asserts**: the
per-insert-tap overhead is ≤ 3000 ns/quantum, absolute. **Should assert**:
consider expressing the same delta as a ratio against a same-run reference
computation, or explicitly document (as `RecoveryPlayheadTests` does) why the
interleaved-min-difference design is expected to be load-tolerant enough in
practice, with the measured evidence to back it.

### 1.3 A related, not-yet-converted site tied to the OPEN roadmap item m23-aw

**`Tests/DAWEngineTests/SoundBankHostingTests.swift:99`** (T1) —
```swift
let prepareTime = await clock.measure { await renderer.prepareAudioUnits(tracks: [track]) }
print("[measured] GM bank prepare-to-ready wall time: \(prepareTime)")
```
`prepareTime` is measured every run and printed but **never asserted at
all** — there is no budget here yet to convert. This is precisely the site
ROADMAP.md's **open** item **m23-aw** already names and proposes fixing
("read the number that is already being printed... assert it against a
fraction of `AUHostRegistry.testPrepareTimeout`, say ≤ 60%, so a shrinking
margin reddens something while there is still margin to act on"). Not
double-filing it here — flagging the connection so this audit's count does
not silently miss it and so it is not mistaken for a fresh finding needing a
new roadmap line.

## 2. All 70 candidate files — verdict ledger

Trivial files grouped by why they are NOT IN SCOPE (each group's members
confirmed individually, not assumed from the count alone):

**Deterministic/injected clock, manually advanced — no live wall-clock read**
(`store.journal.now = { clock }` / `controller.clock = { now }` /
`InsertSpectrumLeases(now:)`, `ContinuousClock.now` captured once and stepped
by hand with `.advanced(by:)`): `Tests/DAWCoreTests/UndoTests.swift`,
`Tests/DAWAppKitTests/ArrangeNudgeTests.swift`,
`Tests/DAWCoreTests/MasterAutomationStoreTests.swift`,
`Tests/DAWCoreTests/MarkerTests.swift`,
`Tests/DAWCoreTests/AutomationStoreTests.swift`,
`Tests/DAWCoreTests/SamplerTests.swift`,
`Tests/DAWCoreTests/MasterChainStoreTests.swift`,
`Tests/DAWCoreTests/InstrumentTests.swift`,
`Tests/DAWCoreTests/EffectChainStoreTests.swift`,
`Tests/DAWCoreTests/BusRoutingStoreTests.swift`,
`Tests/DAWCoreTests/AuditionControllerTests.swift`,
`Tests/DAWCoreTests/AudioUnitCoreTests.swift`,
`Tests/DAWControlTests/EditHistoryCommandTests.swift`,
`Tests/DAWControlTests/FXSpectrumCommandTests.swift`,
`Tests/DAWControlTests/MainActorLivenessTests.swift`.

**Fixture-only `Date(timeIntervalSince1970:)` / fixed-epoch clocks** (crash
recovery manifests, chat persistence timestamps — deterministic by
construction, never a live read): `Tests/DAWCoreTests/MissingMediaEchoTests.swift`,
`Tests/DAWCoreTests/DiagnosticsReporterTests.swift`,
`Tests/DAWCoreTests/CrashRecoveryTests.swift`,
`Tests/DAWControlTests/WireHardeningM16ETests.swift`,
`Tests/DAWControlTests/RecoveryCommandTests.swift`,
`Tests/DAWControlTests/FeedbackBundleCommandTests.swift`,
`Tests/DAWControlTests/CopilotEngineTests.swift`,
`Tests/DAWControlTests/CopilotChatMappingTests.swift`,
`Tests/DAWAppKitTests/SketchpadRowResolutionTests.swift`,
`Tests/DAWAppKitTests/CopilotRailUIModelTests.swift`,
`Tests/DAWCoreTests/CopilotChatPersistenceTests.swift`,
`Tests/DAWControlTests/CopilotChatCommandTests.swift` (comment only, no live
code), `Tests/DAWAppKitTests/GenerationPresenceModelTests.swift`,
`Tests/AIServicesTests/VoiceConversionManagerTests.swift`,
`Tests/AIServicesTests/SidecarManagerTests.swift`.

**Clock reading used only to build synthetic fixture data** (a
`mach_absolute_time()`/`Date()` value stamped onto a synthesized MIDI event
or a file's mtime — never used to measure this test's own elapsed time):
`Tests/DAWEngineTests/MIDIInputManagerTests.swift`,
`Tests/DAWEngineTests/Support/TestSignals.swift`,
`Tests/DAWEngineTests/LoopRecordEngineTests.swift`,
`Tests/DAWEngineTests/AutomationEngineTests.swift`,
`Tests/DAWEngineTests/TransientAnalyzerTests.swift`,
`Tests/DAWEngineTests/StretchEngineTests.swift` (plus one more such use inside
`AudioContentAnalyzerTests.swift`, alongside that file's genuine finding
above).

**Grep false positive — `.measure(` is a DSP function, not a clock**
(`Loudness.measure(...)`, `StereoImage.measure(...)`; the wrong-axis trap
flagged in §"Landmines"): `Tests/DAWCoreTests/LoudnessTests.swift`,
`Tests/DAWCoreTests/LoudnessRangeTests.swift`,
`Tests/DAWCoreTests/ReferenceSlotTests.swift`,
`Tests/DAWEngineTests/ReferenceLaneTransparencyTests.swift`,
`Tests/DAWEngineTests/ReferenceAnalyzerTests.swift`,
`Tests/DAWEngineTests/OfflineBufferRenderTests.swift`,
`Tests/DAWCoreTests/RenderPolicyTests.swift`,
`Tests/DAWCoreTests/LiveLoudnessStreamTests.swift`.

**Zero clock-reading hits at all** (candidate list false positives from the
orchestrator's broader derivation pattern; confirmed by direct grep):
`Tests/DAWEngineTests/StemNullTests.swift`,
`Tests/DAWEngineTests/SidechainEquivalenceTests.swift`,
`Tests/DAWCoreTests/BounceInPlaceTests.swift`,
`Tests/DAWControlTests/SampleLibraryCommandTests.swift`,
`Tests/DAWControlTests/RenderCommandTests.swift`,
`Tests/DAWControlTests/ControlTests.swift`,
`Tests/DAWAppKitTests/EQInstrumentGuideTests.swift`.

**Bounded poll/wait deadline only, never asserted** (precondition guard with
generous margin, not a timing bound):
`Tests/AIServicesTests/WhisperModelInstallCoordinatorTests.swift`,
`Tests/DAWControlTests/SpeechModelInstallCommandTests.swift`,
`Tests/DAWEngineTests/LiveEventRingTests.swift`,
`Tests/DAWEngineTests/GaplessLoopTransportTests.swift` (also carries the
property regression guard, see §1.1),
`Tests/DAWEngineTests/RecoveryOutputPinGateTests.swift` (also carries the
property witnesses, see §1.1).

**Substantive files, individually triaged in §1.1** (the 5 poll-deadline-only
files above are *also* discussed in §1.1's prose, not just this list — they
are counted once, in the poll-deadline group; this list is the remaining §1.1
entries that aren't already counted there):
`Tests/DAWCoreTests/DeadlineRaceTests.swift`,
`Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift`,
`Tests/DAWEngineTests/RecoveryPlayheadTests.swift`,
`Tests/DAWEngineTests/RecoveryCostSplitTests.swift`,
`Tests/DAWEngineTests/EngineRebuildTests.swift`,
`Tests/DAWEngineTests/EngineWatchdogTests.swift`,
`Tests/DAWEngineTests/MainActorStarvationGateTests.swift`,
`Tests/DAWEngineTests/StarvationWitness.swift`,
`Tests/DAWAppKitTests/EQCurveEditorModelTests.swift`.

**Substantive files, CONVERTED-CANDIDATE or related, in §1.2/§1.3**:
`Tests/DAWEngineTests/AudioContentAnalyzerTests.swift`,
`Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift`,
`Tests/DAWEngineTests/MIDIControllerInstrumentTests.swift`,
`Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift`,
`Tests/DAWEngineTests/SoundBankHostingTests.swift`.

Count check: 15 + 15 + 6 + 8 + 7 + 5 + 9 + 5 = **70.** All candidate files
accounted for.

## 3. Count

**6 CONVERTED-CANDIDATE assertion sites** (5 firm + 1 borderline —
`InsertSpectrumCoverageTests`, whose interleaved-min design is closer to the
target shape than the other four; see its own entry), across 5 files.

Of these, **4 also lack a mutation discriminator** (nothing in-tree proves
the budget can trip on a real regression): #2, #3+#4, #5, #6 below. #1
(`DeadlineRaceTests`) had its underlying defect discriminated by an
out-of-band standalone harness at m23-at's close-out, not by a permanent
in-tree mutation test of the median ceiling specifically — and per §1.1's
control-flow reading, the median ceiling would never even be reached under
that defect (the sample-size `#require` fails first) — so its discriminator
status is "historically demonstrated, not standing, and structurally unlikely
to be reached at all under the regression it targets."

**Canonical list — the numbering used everywhere else in this document**
(§1.2's presentation order, not a priority order):

1. `Tests/DAWCoreTests/DeadlineRaceTests.swift:197` (pre-triaged, confirmed)
2. `Tests/DAWEngineTests/AudioContentAnalyzerTests.swift:677`
3. `Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift:229`
4. `Tests/DAWEngineTests/AUPrepareRenegotiationStressTests.swift:230`
5. `Tests/DAWEngineTests/MIDIControllerInstrumentTests.swift:439`
6. `Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift:1061`

**Ranked by real-world exposure, not just shape** (the count alone doesn't
tell whoever picks this up which to fix first — this ranking uses different
numbers than the canonical list above; read each entry by file name, not by
position):

1. **`AUPrepareRenegotiationStressTests.swift:229-230`** — highest priority,
   on evidence checked directly rather than recalled: the suite is confirmed
   **not** `.serialized` (grepped `@Suite`, no trait present), it collects
   30+ real `ContinuousClock().measure` prepare samples under deliberate
   renegotiation/teardown contention, and `minSeconds < 1.0` is a **minimum**
   over that whole set — a min bound over many contended AU-prepare samples
   is the single most load-exposed shape of any finding here.
   > ⚠️ **THIS RANKING SENTENCE IS BACKWARDS — see §6.** A MINIMUM over many
   > samples is the LEAST load-exposed channel available, not the most: it
   > selects the least-disturbed sample, which is the very reasoning this
   > same document applies (correctly) to `InsertSpectrumCoverageTests`.
   > MEASURED: loaded min is 0.061–0.065 s against the 1.0 s bound (~15×
   > headroom) while the median sits at 2.45–3.15 s against 8.0 s (~2.5×).
   > **The file is still the right rank-1 pick — but because of `:230`, the
   > median, not `:229`, the min.**
   This converges
   with, and is corroborated by, `ROADMAP.md:798` (m23-at: GM prepare rose
   17–22 s → 24.3–26.9 s post-policy) and `ROADMAP.md:490` (m23-ab-3: 20–24 s
   under full-suite load) — both read directly (§1.2's AUPrepare entry now
   quotes them in full) — and `ROADMAP.md:796` (m23-as-2) independently names
   this same file as the priority pick.
2. `Tests/DAWCoreTests/DeadlineRaceTests.swift:197` — mechanism-level finding
   (§1.1), reintroduced in the same cycle the item was filed to prevent it,
   and shown by the control-flow reading in §1.1 to be structurally unlikely
   to ever be reached by the regression it targets.
3. `Tests/DAWEngineTests/AudioContentAnalyzerTests.swift:677` — genuine
   full-suite CPU exposure (`.serialized` for I/O sharing only), but a single
   5-minute-audio analysis rather than dozens of AU prepares, so less sample
   pressure than #1.
4. `Tests/DAWEngineTests/MIDIControllerInstrumentTests.swift:439` — weakest
   of the four new findings; already partially load-cancelling (same-run
   subtraction) and self-documented as "sanity envelope only."
5. `Tests/DAWEngineTests/InsertSpectrumCoverageTests.swift:1061` — borderline;
   already the closest to the target shape (interleaved-min, explicit
   anti-vacuity check, ~15× margin) of the five.
   > ⚠️ **"~15× margin" is ambiguous here and reads as margin-to-ceiling — see
   > §8.** 15× is ceiling-vs-DESIGN-TARGET (3000 ns ÷ ~200 ns), stated
   > deliberately in the source. Ceiling-vs-MEASURED is **~40×** (65.1–74.6 ns
   > over 8 full-suite runs). §1.2's phrasing at line 406 is correct; this one
   > is not.

Plus one **NO MUTATION-DISCRIMINATOR-adjacent** finding that isn't a
CONVERTED-CANDIDATE because no budget exists yet to convert:
`Tests/DAWEngineTests/SoundBankHostingTests.swift:99` (`prepareTime`, printed
only) — already the exact subject of open roadmap item **m23-aw**.

**Recommendation for the orchestrator's split decision**: 6 sites across 5
files is small enough to fold into the existing m23-aw-adjacent cleanup pass
rather than opening a whole new roadmap item — but `AUPrepareRenegotiationStressTests`
and `AudioContentAnalyzerTests` both touch AU-hosting/audio-analysis
performance characterization that a `daw-architect`/`audio-dsp-engineer` pass
already owns nearby (m23-aw), so routing the conversions alongside that work
avoids a third pass through the same files. **Superseded — see §5**: this
recommendation was overruled and the conversion half was filed as its own
item, `docs/ROADMAP.md` **m23-as-2** (line 796), which independently arrived
at the same "do `AUPrepareRenegotiationStressTests` first" priority as the
ranking above, citing the same measured figures now quoted directly in this
document's §1.2 AUPrepare entry and this section's rank-1 justification
(`ROADMAP.md:490`'s 20–24 s and `ROADMAP.md:798`'s 24.3–26.9 s) — the two
analyses converge on the same file for the same underlying reason. Read
m23-as-2 for the currently-authoritative plan; this section is left
as-written for the audit trail.

## 4. Landmines (fit neither pattern cleanly, still worth recording)

1. **`RecoveryPlayheadTests`' 0.25/0.10-beat ceilings are hardware-config
   fragile, not suite-load fragile** — self-disclosed in source ("AT 2048
   FRAMES THIS FILE FLAKES ON A CORRECT ENGINE"), with a re-derivation
   formula already written down. Not a suite-load anti-pattern instance (the
   file's whole point is immunity to that), but a landmine for whoever
   changes the app's default I/O buffer size or runs the suite on different
   audio hardware.

2. **`EngineWatchdogTests`' `maxLag <= 1.2` (line 417) is a stale duplicate**
   of `RecoveryPlayheadTests`' now-`0.25` ceiling — same lag-metric design,
   never retightened when m23-bs-2 landed and tightened the sibling file's
   number. Not incorrect, but two nearly-identical regression guards with
   inconsistent numbers is a maintenance trap: a future author fixing one
   ceiling for a buffer-size change has no signal that this file's copy needs
   the same edit.

3. **The wrong-axis grep trap, encountered firsthand, not just warned
   against**: `\.measure\(` matched `Loudness.measure(audio)` and
   `StereoImage.measure(left:right:)` — pure DSP functions unrelated to
   timing — in 8 of the 70 candidate files. A grep on `.measure(` alone
   (without requiring a preceding `Clock()`/`clock` receiver) silently floods
   a sweep with audio-measurement false positives. Any future re-run of this
   audit should grep for `ContinuousClock().measure`/`clock.measure` as a
   receiver-qualified pattern, not a bare method name.

4. **The brief's own warning about grepping assertion text is empirically
   correct and worth restating from evidence, not just instruction**: every
   genuine finding in this audit (`AudioContentAnalyzerTests`,
   `AUPrepareRenegotiationStressTests`, `MIDIControllerInstrumentTests`,
   `InsertSpectrumCoverageTests`) uses local variable names (`seconds`,
   `minSeconds`/`median`, `perEventMicroseconds`, `delta`) that a search for
   the word "duration" would have missed entirely.

## References

- Reference/target shape: `Tests/DAWEngineTests/MainActorStarvationGateTests.swift`,
  `Tests/DAWEngineTests/StarvationWitness.swift`,
  `Tests/DAWAppKitTests/EQCurveEditorModelTests.swift` (lines 718–927, the
  `recomputeRegressionTripsCalibratedBudget` model itself).
- Pre-triaged calibration sites: `Tests/DAWCoreTests/DeadlineRaceTests.swift:197`,
  `Tests/DAWEngineTests/RecoveryAnchorContinuityGateTests.swift:641`.
- Related open roadmap item: `docs/ROADMAP.md` m23-aw (the
  `SoundBankHostingTests` `prepareTime` tripwire).

---

## 5. Orchestrator verification (2026-08-03)

This audit was produced by a delegated `qa-test-engineer` pass and then checked
independently. What was re-derived from scratch, not taken on report:

- **The candidate set.** The 70-file list was derived independently from the
  clock-reading spellings and every one of the 70 was confirmed to appear in
  §2's ledger — **0 missing**. This is what makes "every site found" checkable.
- **Anti-pattern (b) = zero.** Re-run with a *wider* alternation than §0's
  (adding `processorCount|thread_info|zone_statistics`) and with comment lines
  stripped: **no live hit anywhere in `Tests/`**. The pattern was then proven
  to work by searching `blocks_in_use` alone and getting the expected comment
  lines back — an empty result that confirms the hypothesis is a broken regex
  until shown otherwise.
- **`DeadlineRaceTests:197`, `AudioContentAnalyzerTests:677`,
  `AUPrepareRenegotiationStressTests:229-230`, `MIDIControllerInstrumentTests:439`,
  `SoundBankHostingTests:99`** — all read directly at source. Verdicts confirmed.

**One verdict was adjudicated against the orchestrator's own first reading.**
`InsertSpectrumCoverageTests:1061` was initially triaged as JUSTIFIED IN PLACE
on the grounds that an interleaved-min *difference* cancels ambient load. §1.1
is right and that reasoning was wrong: **subtraction cancels ADDITIVE offsets,
not MULTIPLICATIVE ones.** Under a proportional slowdown of factor *k*,
`delta = k·a₀ − k·b₀ = k·(a₀ − b₀)` — the delta scales with load, so a busy
machine can breach the absolute 3000 ns ceiling with no regression present.
It is a genuine CONVERTED-CANDIDATE, correctly marked borderline and most
defensible of the set. **Count stands at 6.**

**Where the orchestrator differs from §3's recommendation:** §3 suggests folding
the conversions into m23-aw. Filed instead as its own item (**m23-as-2**),
because m23-aw has a distinct scope (its headroom pin measures nothing) and
silently widening it hides the conversion work rather than scheduling it. The
adjacency §1.3 identifies is real and is recorded on both items so whoever takes
either can batch the file visits.

## 6. MEASURED — `AUPrepareRenegotiationStressTests`, and two corrections it forces

Added by the orchestrator 2026-08-03, at the start of m23-as-2. **This section
is authoritative over §1.2's and §3's claims about this file.** Everything
below is a reading from `[measured] m19-e contended prepares`, n=32 per run,
on this tree — not a recollection and not an inherited figure.

| condition | min | **median** | p90 | max |
|---|---|---|---|---|
| isolated (`--filter AUPrepareRenegotiationStressTests`) | 0.000168 | **0.000780** | — | 0.0511 |
| full suite, run A | 0.065457 | **3.149543** | 14.143 | 23.206 |
| full suite, run B | 0.061028 | **2.466742** | 12.293 | 18.452 |
| full suite, run C | 0.062611 | **2.451709** | 11.041 | 24.886 |

### Correction 1 — the cited figures are a MAX-regime number, not a median

§1.2 and §3 argue the `median < 8.0` bound sits "roughly 3× *below* a measured
24–27 s regime". **That compares a worst-case single prepare to a median
bound.** m23-ab-3's 20–24 s and m23-at's 24.3–26.9 s describe ONE contended GM
prepare, and they land squarely in this suite's measured **max** band
(18.5–24.9 s) — a channel this test deliberately does **not** assert.

An intermediate correction claimed those figures belonged to a different
suite's prepare path. **That was also wrong** and is recorded here so it is not
re-derived: this suite's `bankTrack` builds
`SoundBankConfig(source: .generalMIDI)` and calls the same
`AUHostRegistry.prepare`, so it is the same GM path. The error was never the
path — it was the statistic.

**The real finding, which survives:** the bound was calibrated as "4× the worst
measured median" against **2.02 s** (2026-07-16). Today's worst median is
**3.15 s**. The effective margin has eroded **4× → 2.5×**. Real, worth acting
on, and roughly an order of magnitude smaller than §1.2 claims.

> ⚠️ **SUPERSEDED BY A LARGER SAMPLE — see `docs/research/design-m23as2-prepare-estimator.md`.**
> `daw-architect` took two further green full-suite runs (D, E) for the design
> pass. **Run D's median is 4.637 s**, so the worst-of-five is 4.637, not 3.15,
> and the effective multiple is **1.73×**, not 2.5×. My three runs were not a
> big enough sample to bound this channel — which is itself the point: the
> median is the noisiest of the four channels (run-to-run spread 1.89× vs the
> min's 1.52×) while retaining the least margin.
>
> **Two findings of that design pass that this document did not reach:**
>
> 1. **The bound's derivation rule no longer has a solution.** `4 × 4.637 =
>    18.55 s`, but the measured `max/median` ratio (4.44–10.15) puts the median
>    at which the worst prepare hits the horizon and flips `.failed` at
>    **5.9–13.5 s**. No number is simultaneously "4× the worst measured median"
>    and "below the failure horizon". A bound whose rule is unsatisfiable
>    cannot be re-derived — only deleted or replaced by a different rule.
> 2. **The rule's second clause is VOID, and has been since m23-at.**
>    `timedPrepare` passes no `timeout:`, so it gets
>    `AUHostRegistry.defaultPrepareTimeout` =
>    `TestEnvironment.isRunningTests ? testPrepareTimeout : productionPrepareTimeout`,
>    and `testPrepareTimeout` is **60 s**. `swift test --disable-xctest` runs
>    `swiftpm-testing-helper`, which `isSwiftTestProcess` matches. **I verified
>    this chain myself, module by module.** The horizon in the process where
>    the assertion executes is 60 s, not the 10 s the comment claims.
>
> ⚠️ **A THIRD STALE REFERENCE, found by me and not by the design:** layer 1 of
> the same comment block (`:216`) also reads *"each prepare races the
> registry's 10 s timeout"*. Equally void, same cause. Both are being fixed by
> reference to the named constant rather than a re-typed number.
>
> **Verdict for this site: DELETE `#expect(median < 8.0)`, keep the median in
> the print, keep `min < 1.0` as the detector and give it a discriminator.**
> The median bound sat *inside* the 5.9–13.5 s failure-onset band, so it fired
> at or after the `.ready` assertions it duplicated — a lossy restatement of a
> hard bound the test already asserts exactly.

### Correction 2 — the min channel is the robust one, and the ranking inverted it

§3 ranks `minSeconds < 1.0` as "the single most load-exposed shape of any
finding here". A minimum over 32 samples is the **least**-disturbed estimator
in the set — it selects the sample that got the cleanest run. Measured, it
holds ~15× headroom under full-suite load (0.061 s vs 1.0 s) versus the
median's 2.5×. **`:229` is the healthy assertion in this file; `:230` is the
one under pressure.**

### Consequence for the m23-as-2 conversion — the prescribed shape does not apply

m23-as-2 inherits from `EQCurveEditorModelTests` (m23-ab-2) the prescription
"convert to a same-run calibrated ratio". **For this site that instrument is
not merely unnecessary, it is inverted.** AU prepare wall time is dominated by
main-actor QUEUE WAIT, which contaminates *additively*, not by CPU slowdown,
which contaminates *multiplicatively*. Dividing by a trivial-hop calibration
gives `(queue + work) / queue`, which tends to **1 under load and to ∞ when
idle** — the opposite of a load-invariant bound. The m23-ab-2 ratio is correct
for `EQCurveEditorModelTests`, where the contaminant genuinely is CPU
slowdown; the two sites need different instruments and the item text should
stop implying one shape fits all six.

⚠️ **`p90` (11.0–14.1 s) and `max` (18.5–24.9 s) are unasserted and MUST STAY
unasserted.** This table is the evidence a future author needs in order not to
"helpfully" add a max bound — the existing comment declines to assert the max
for exactly this reason, and the numbers now back it.

## 7. `DeadlineRaceTests.swift:197` re-verdicted — bounded sample space, no denominator available

Also orchestrator, 2026-08-03, from reading the control flow rather than the
assertion. **This section revises §1.1's and §3's rank-2 treatment.**

Constants (read, not recalled): `budget` 200 ms (`:111`), `medianCeiling`
600 ms (`:112`), `requiredArmings` 10 (`:113`), `armingsPerRound` 4 (`:114`),
`maxRounds` 8 (`:115`), hog 1000 ms. Recorded measurement from m23-at's
close-out: 12 armings at 0.200–0.210 s.

### This is NOT the open-ended wall-clock shape m23-as is about

An arming is only admitted to the sample if `m.end < spinEnd` (`:167`).
Every counted elapsed is therefore **structurally bounded above by the hog
window, ~1000 ms** — the sample space is closed. Contrast the AUPrepare median,
which is bounded by nothing.

More importantly, load's effect here is routed into an *honest* failure. A
starved machine pushes armings past `spinEnd`, so they are discarded (`:172`)
rather than counted late; the sample eventually fails the `#require` at `:191`,
whose message explicitly separates the two cases: *"the machine was too starved
to run the experiment, which is not the same as the experiment failing."* The
hog-start wait has a deliberately generous 90 s cap (`:135`) with the same
reasoning spelled out. **The escape hatch m23-as exists to demand is already
built.**

### There is no same-run denominator to convert to

I considered expressing the median as a fraction of the observed hog window —
same round, same load, zero new machinery. **It does not work.**
`spinHoldingMainActor` (`:70-76`) busy-spins `while clock.now < deadline`, so
the window is ~1000 ms of wall clock *regardless of load*. A constant is not a
calibration. No other same-run load-sensitive quantity is measured in this
test, and manufacturing one would mean adding a probe to a test whose whole
design is about not perturbing the actor.

### Verdict

**Least urgent of the six, and a ratio conversion is not available.** Residual
exposure is real but small and bounded: under moderate load the surviving
armings skew toward the late end of the window, so the median can drift from
~0.205 s toward 600 ms with no regression present — ~2.9× headroom, inside a
hard ~4.9× structural cap.

The defensible change is **not** a ratio but a drift tie: `medianCeiling` is a
bare `.milliseconds(600)` sitting two lines below `budget = .milliseconds(200)`,
and the assertion's own message reasons about it as *"far slower than its
budget"*. Tying the two makes that relationship explicit and stops them
drifting apart if the budget is ever retuned. That is a one-home/drift fix in
the m23-ar idiom, **not** a load-robustness fix, and should be described as
such rather than counted as an m23-as conversion.

⚠️ **THE TIE MUST BE ADDITIVE, NOT MULTIPLICATIVE — I first wrote `budget * 3`
here and that is wrong, in exactly the way this whole cycle has been
correcting.** Measured, the median is **0.200–0.210 s against a 200 ms
budget**: the deadline resolves at `budget + ~5 ms`. The 600 ms ceiling is
therefore not "3× the budget", it is **"the budget plus 400 ms of tolerated
scheduling lateness"** — and that lateness is a property of getting a detached
task back onto a core, which does **not** scale with the budget. Retune the
budget to 50 ms and `budget * 3` gives a 150 ms ceiling while the real
lateness is unchanged, silently tightening the assertion by 4×.

The honest spelling is `budget + .milliseconds(400)`, with the 400 named for
what it is — tolerated wake-up lateness, measured at ~5 ms and given two
orders of magnitude of headroom. **A multiplicative tie between an additive
pair is the same category error as a ratio against an additive contaminant
(§6); it just hides better because both numbers are small.**

⚠️ §1.1's separate criticism — that this ceiling's *discriminating power* has
never been exercised, because the primary per-arming `#expect(m.timedOut)` at
`:176` and the sample-size `#require` both fire first under the targeted
regression — **stands and is untouched by this section.** Low flake risk and
low detection value are independent properties, and here both are true.

## 8. MEASURED MARGINS FOR ALL SIX SITES — and what they do to the item

Orchestrator, 2026-08-03. Every site prints a `[measured]` line; the numbers
below are harvested from full-suite logs already on disk, **not re-reasoned**.
Sample provenance: 8 prints per site, each from a log whose final line reports
a complete run (`Test run with 4692 tests`, one at 4682).

⚠️ **THREE NUMBERING SCHEMES NOW EXIST FOR THESE SIX SITES. READ THIS BEFORE
CITING A NUMBER.** They do not agree, and a bare "#3" is ambiguous:

- **§2's ledger order** — the canonical enumeration, by file. `daw-architect`'s
  design doc header uses this when it says it covers *"sites #3/#4 of the
  m23-as canonical list"* — i.e. `AUPrepare:229` and `:230`.
- **§3's exposure ranking** — 1 AUPrepare, 2 DeadlineRace, 3 AudioContentAnalyzer,
  4 MIDIController, 5 InsertSpectrum. Ranked by *reasoned* exposure, before
  any margin was measured, and §8 below shows that ranking was wrong twice.
- **§8's margin ranking** — the table immediately following, ordered by
  MEASURED margin ascending.

**When citing across documents, name the FILE AND LINE, never the index.**
`AUPrepare:230` is unambiguous; "#1" is three different sites depending on
which section the reader is in. The numbers below are a margin ordering and
carry no other meaning.

| # | site | assertion | MEASURED | margin |
|---|---|---|---|---|
| 1 | `AUPrepareRenegotiationStressTests:230` | `median < 8.0` s | 2.45–**4.64** s | **~1.73×** |
| 2 | `DeadlineRaceTests:197` | `median <= 600` ms | ~0.205 s | ~2.9× (capped ~4.9×) |
| 3 | `AudioContentAnalyzerTests:677` | `seconds <= 5.0` | 1.229–1.274 s | ~3.9× |
| 4 | `AUPrepareRenegotiationStressTests:229` | `min < 1.0` s | 0.061–0.065 s | ~15× |
| 5 | `InsertSpectrumCoverageTests:1061` | `delta <= 3000` ns | 65.1–74.6 ns | **~40×** |
| 6 | `MIDIControllerInstrumentTests:439` | `< 100` µs/event | 0.0387–0.0448 | **~2 200×** |

⚠️ **Margin is NOT the property m23-as is about.** The item is about *absolute
wall-clock* bounds; margin is how far a bound sits from its value **on this
machine under the contention these 8 runs happened to contain**. They are
different properties and this table ranks by the second. It is decision-useful
anyway — a 40× or 2 200× margin is not crossed by run-to-run variance on any
plausible machine — but it is NOT proof of load-insensitivity, and the next
author runs on different hardware.

⚠️ **Row 5's ~40× corrects an earlier "~15×" in §3.** That 15× is
ceiling-vs-**design-target** (3000 ns ÷ ~200 ns), which the in-source comment
states deliberately — *"~15× the design target on purpose: this leg guards an
ARCHITECTURAL regression … not a microbenchmark"*. It is not
ceiling-vs-measured. Two different ratios; §3 quoted one as the other.

Two observations that are not visible from reading the assertions:

**(i) `AudioContentAnalyzerTests:677` did not respond to the contention these
runs contained.** Across 8 full-suite runs it spans 1.229–1.274 s — a **3.7 %
spread**. The runs genuinely did differ in load: the AUPrepare median in the
*same logs* spans 2.45→3.15 s (29 %), so this is an internal control, not eight
identical conditions.

⚠️ **CORRECTED 2026-08-03 (m23-as-2b), and both halves of the original claim
were wrong.** This paragraph used to read *"a pure-CPU DSP pass over a 5-minute
WAV with no actor or I/O in the timed region, so it is the site where the
m23-ab-2 ratio shape applies most cleanly."*

1. **There IS I/O in the timed region.** `AudioContentAnalyzer.analyze(fileAt:)`
   (`Sources/DAWEngine/Analysis/AudioContentAnalyzer.swift:62`) opens an
   `AVAudioFile` via `readMonoWindow` and reads a 300 s window before any DSP
   runs. The mechanism claim was asserted from the assertion site without
   reading the callee. It survives only because the test *writes* that WAV
   immediately beforehand, so every read is warm in the page cache — which is
   itself a reason the number is stable, and a machine-specific artifact.
2. **The ratio shape does NOT apply here — it is measurably the wrong
   instrument.** See §9. Isolated→loaded inflation is **~1.05×**, so there is
   no contamination to cancel; and the m23-ab-2 ratio's own documented healthy
   spread (40 % isolated, 141 % adversarial) is *wider* than this quantity's
   raw spread (8.3 %). Converting would degrade the discriminator ~5×.

**(ii) The bottom three are tripwires, not budgets, and #6 says so out loud.**
`MIDIControllerInstrumentTests:439` carries the comment *"Sanity envelope only
— the number itself is the rider deliverable"*, and the measurement bears that
out: a 2 200× margin cannot flake, and equally cannot detect anything short of
a catastrophic regression. **Converting a 2 200× envelope into a calibrated
same-run ratio adds machinery and removes the plain reading, in exchange for
robustness it already has.** The honest defect at #5 and #6 is not
load-fragility — it is the m23-as-1 law *a budget nobody has seen fire is a
budget nobody has calibrated*. The remedy for that is a **discriminator**, not
a ratio.

### Consequence: the sites are three classes, not one

m23-as-2 as filed prescribes one shape ("same-run calibrated ratios") for all
six. The measurements say they are three different problems:

- **Additive / actor-queue-bound** — `AUPrepare:229`, `:230`. A ratio against a
  CPU or hop calibration is *inverted* here (§6). Needs its own instrument.
- **Multiplicative / CPU-bound** — `AudioContentAnalyzer:677`,
  `InsertSpectrum:1061`, `MIDIController:439`. The m23-ab-2 ratio is the
  correct shape, but only #3 has a margin small enough to justify the work;
  #5 and #6 need discriminators instead.
- **Structurally bounded, no denominator available** —
  `DeadlineRace:197` (§7).

**The item text should be corrected to say so.** Ranking by measured margin
also reorders the work: only site #1 is under 3× and eroding, and it is the
one whose prescribed fix does not apply.

### The sharper finding: "convert 6 sites" is the wrong completion condition

Two facts established separately now compose. m23-as-1 found **4 of 6 sites
lack a mutation-discriminator**, under the law *a budget nobody has seen fire
is a budget nobody has calibrated*. §8 now measures that **#5 and #6 have
margins (40×, 2 200×) that make them undetectable in practice**. Together:

> **#5 and #6 are not budgets at all. They are tripwires — too robust to
> flake, and too loose to detect.** Converting them to calibrated ratios is
> category-confused in *both* directions: it buys robustness they already
> have, against a sensitivity problem it does not fix. What they lack is a
> discriminator, and a discriminator is not a conversion.

Site #6 says this about itself in-source (*"Sanity envelope only — the number
itself is the rider deliverable"*), and #5's comment likewise declares it an
architectural guard rather than a microbenchmark. **Both are honest about what
they are; the audit misread them as defective budgets.**

The realistic deliverable for m23-as-2 is therefore:

| site | what it actually needs |
|---|---|
| #1 `AUPrepare:230` | **DELETE the assertion**, keep the print. Ratio is inverted here AND the bound's derivation rule is unsatisfiable — `daw-architect` design delivered, `docs/research/design-m23as2-prepare-estimator.md`. Not "a new instrument": no instrument is warranted. |
| #2 `DeadlineRace:197` | an ADDITIVE drift tie (`budget + 400 ms`), not a conversion and not `budget * 3` (§7) |
| #3 `AudioContentAnalyzer:677` | the m23-ab-2 ratio — the one true conversion, and marginal at 3.9× |
| #4 `AUPrepare:229` | nothing; healthy at ~15× |
| #5 `InsertSpectrum:1061` | a discriminator |
| #6 `MIDIController:439` | a discriminator |

⚠️ **This changes what "done" means for m23-as-2.** If the item was filed with
"6 conversions" as its completion condition, satisfying the table above is a
*different bar* — and that must be stated explicitly in the item rather than
quietly met. **Do not rewrite the item until #1 has a replacement shape:** the
reframing's central claim is that the prescribed fix does not apply to the one
site that needs it, and an item rewritten to say "the prescription is wrong"
with nothing in its place is worse than the text it replaces.

---

## 9. MEASURED — `AudioContentAnalyzerTests:677`, and why the conversion is DECLINED

**m23-as-2b, 2026-08-03.** The item filed this site as *"the one true ratio
conversion of the six."* Measurement says otherwise, and the reason generalises.

### 9.1 The inflation test (m23-as-2's headline law, applied)

The law says: take the same quantity isolated and under a full parallel suite,
read the inflation factor, and let the number pick the instrument (~2–10× = CPU
contention = multiplicative = ratio; ~100×+ = queueing = additive = ratio
inverted).

| condition | samples | range | spread |
|---|---|---|---|
| condition | samples | range | spread |
|---|---|---|---|
| isolated (`--filter`, sequential) — **all taken today, this tree** | 5 | 1.176 – 1.209 s | 1.028× |
| full parallel suite — **historical, prior cycles' logs, other trees** | 8 | 1.229 – 1.274 s | 1.037× |
| full parallel suite — **today, this tree** | 1 | 1.2102 s | — |
| **combined** | **14** | **1.176 – 1.274 s** | **1.083×** |

⚠️ **The loaded rows are two populations, not one, and the seam matters.** The
1.210 floor comes from the SINGLE fresh sample; the eight historical samples
floor at 1.229 and were taken against different trees. Do not read "9 loaded
samples, 1.210 floor" — that floor is one run on one tree. The verdict is
unaffected (1.08× is nowhere near 2–10× under any grouping), but a future cycle
inheriting a merged floor would be inheriting something no repeated measurement
established. Per this audit's own §8 rule, only the isolated-vs-today
comparison carries a co-measured control.

**Inflation factor: ~1.00–1.08×, call it ~1.05×.**

⚠️ The 9th loaded sample was taken fresh on today's tree (**1.2102 s**, in a
clean 4693-test / 483-suite run, 92.1 s) and it **overlaps the isolated range** —
1.210 against an isolated ceiling of 1.209, an inflation of 1.0008×. The single
most load-exposed comparison available for this site is therefore
indistinguishable from no load at all.

That is **neither band**. The law as written at m23-as-2a has a gap: it named
the multiplicative case and the additive case, and assumed every site is one or
the other. **A third class exists — sites that do not respond to load at all,
where the right answer is to convert NOTHING.** There is no contaminant to
cancel, so every normalisation is pure cost.

### 9.2 The load-bearing measurement: a ratio has a NOISE FLOOR

Declining could have rested on "there's nothing to cancel." That is only half
an argument — it says the conversion is unnecessary, not that it is harmful.
The other half is measurable, and the numbers were already in the tree:
`EQCurveEditorModelTests.swift:776-792` records the m23-ab-2 calibration
probe's own **healthy-ratio** spread.

| quantity | isolated | full-suite | adversarial (20 CPU hogs) | worst-case spread |
|---|---|---|---|---|
| **m23-ab-2 ratio** (what a conversion here would produce) | [0.814, 1.139] | [0.804, 1.167] | [0.494, 1.192] | **2.41×** |
| **this site, raw absolute seconds** | [1.176, 1.209] | [1.229, 1.274] | not measured | **1.083×** |

**The instrument is ~5× noisier than the thing it would measure.** A ratio's
discriminating power is bounded by its denominator's variance, and m23-ab-2's
comment says so itself — *"the ratio's numerator and denominator are only
APPROXIMATELY common-mode under adversarial scheduling, not perfectly so."*

> **THE LAW: normalisation has a noise floor. A same-run ratio is correct only
> when the contamination it removes EXCEEDS the calibration probe's own
> variance. Measure both before converting — the probe's spread is a number you
> can look up, not a property you may assume.**

This is also why m23-ab-2 was right *at its own site* and wrong here: there,
the absolute bound sat at 65–75 % of budget with zero load and contention moved
it 1.2–1.6×, so a 40 %-noise instrument was still a net win. Here contamination
is 5 % and the instrument's noise is 40 %. **Same shape, opposite verdict,
decided by measurement rather than by which one reads as more rigorous.**

### 9.3 Verdict

**DECLINED — justified in place, not converted.** m23-as's gate is *"every site
found, each either converted **or justified in place**"*; this is the second
branch, and §9.1–9.2 is the justification. The `#expect(seconds <= 5.0)` bound
stays byte-for-byte as it is.

⚠️ **Caveats, stated rather than buried.** (a) The stability is partly an
artifact: the test writes the WAV immediately before reading it, so the I/O in
the timed region (§8, corrected) is always warm-page-cache — on a cold cache,
or a machine with slower storage, the inflation factor could look quite
different. (b) All of this is one machine. The inflation test is cheap and
re-runnable; the *method* transfers, the *numbers* do not. (c) No adversarial
(deliberately CPU-saturated) sample was taken for this site — the ~1.05× covers
natural full-suite contention only.

### 9.4 Filed, not fixed: the unasserted 2 s design target

`AudioContentAnalyzerTests.swift:646` documents *"§7: ≤ 2 s typical, 5 s hard
for a 5-min file"* and the suite asserts **only the 5 s hard bar**. The 2 s
typical target is prose that no machine checks — the m23-as-1 family of finding.

Measured against it: 1.189 s isolated median → **1.68×** margin; 1.274 s loaded
worst → **1.57×**. That is a real budget, unlike the 5 s bar's 3.9×.

**Deliberately NOT added in this cycle**, for the reason this cycle exists: a
1.57× loaded margin with no adversarial sample is a flake candidate, and
asserting it would be classification-by-reasoning — the exact move the headline
law forbids. Filed as **m23-by** so a cycle that runs the adversarial load test
can decide it on evidence.
