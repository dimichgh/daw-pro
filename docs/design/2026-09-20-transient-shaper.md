# `.transientShaper` — design, frozen contract, and verification plan

**Status:** DESIGN ONLY. No code was written or changed for this document.
**Date:** 2026-09-20
**Author:** daw-architect
**Roadmap home:** `docs/ROADMAP.md:4415` — the `(m39-n … m39-ab)` remaining-ranked-suite bucket,
the entry reading `` `.transientShaper` (⚠️ **price the DETECTOR, not the shaper** …) `` at
`docs/ROADMAP.md:4418-4419`.
**Per-item contract inherited from:** `docs/design/2026-09-19-creative-effects.md` — §6.0 (rules every
new kind inherits, `:703-759`), §9 (demo obligations, `:1265-1344`), §11.0 (the measured file set,
`:1430-1463`), §11.2 (standing constraints, `:1578-1609`).

---

## 0. Two corrections to the brief, recorded first because everything below depends on them

**0.1 The per-item contract is NOT in `docs/design/2026-09-19-modulation-layer.md` §11.** It is in
`docs/design/2026-09-19-creative-effects.md`. Measured: `grep -in "transient"` over the
modulation-layer doc returns **zero** hits, and so does `grep -c "phaser"` — while `grep -n "^## "`
over the same file returns **62** heading matches, so the file is readable and the pattern works.
The transient-shaper row is `creative-effects.md:116` (the ranking table, rank 8) and its build/leg
ids are at `:1499` and `:1572`. **Positive control satisfied:** the grep that found nothing in one
file found plenty in the other with the identical command shape.

**0.2 Item id: this document recommends `m39-y`, not `m39-p`.** The two tables in `creative-effects.md`
disagree — the build table at `:1499` says `m39-p`, the leg table at `:1572` says
`` `m39-y` `.transientShaper` (M — **price the detector, not the shaper**) ``. Neither id is spent in
`docs/ROADMAP.md` (measured: `grep -n "(m39-p)"` and `grep -n "(m39-y)"` both return nothing;
`grep -n "(m39-o)"` returns `:4354` and `grep -n "(m39-x)"` returns `:1190`, so the probe can find an
id that exists). **The tie-break is precedent, and it is consistent three times:** every previous
member of the ranked suite shipped under its **leg-table** id — `.phaser` as `m39-x`
(`ROADMAP.md:1190`, erratum recorded at `:1206-1208`), `.tapeDelay` as `m39-aa` (`:4377`, erratum at
`:4384-4386`), the delay-line extraction as `m39-j-0` (`:4159-4161`). The transient shaper sits in the
**same Leg 4 row** as `.phaser` (`creative-effects.md:1572`), which shipped as its leg-table id.
⛔ `docs/ROADMAP.md` is the orchestrator's file; this is a **recommendation**, and the orchestrator
files it.

---

## 1. The decision, in one paragraph

`.transientShaper` is a **zero-latency, gain-only insert** driven by a **three-envelope differential
follower running in the linear amplitude domain, whose differentials are taken as dB RATIOS**. Two
independent differentials — one that is non-zero only while the signal is rising faster than its own
lagged reference (ATTACK), one that is non-zero only while it is falling faster than its own lagged
reference (SUSTAIN) — each drive a user-set dB amount through a declared normalisation. It allocates
nothing on the render path, needs **no lookahead**, reports **`latencySamples == 0`**, and therefore
**adds no new latency source to the sample-exact insert PDC measured at m25-n**. At its defaults it is
**bit-exact dry**, which is what makes the byte-identity gate in §7 possible.

---

## 2. Why `TransientAnalyzer` cannot be reused — the evidence

The roadmap's warning (`docs/ROADMAP.md:4418-4419`) is correct, and here is what I read.

**File:** `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Analysis/TransientAnalyzer.swift` (311 lines).

| Claim | Evidence (file:line, read) |
|---|---|
| It declares itself off the render path | `:24-26` — *"REAL-TIME SAFETY: this type is never referenced from the render path. It allocates and does file I/O freely because it only ever runs inside a detached task."* |
| Its input is a **file**, or a whole `[Float]` array — never a buffer | `:66` `analyze(fileAt url: URL, …)`; `:77-79` `analyze(monoSamples: [Float], sampleRate:, sensitivity:)`. There is no streaming/per-quantum entry point. |
| It allocates on every call, repeatedly | `:90` `var candidates: [(frame: Int, flux: Double)] = []` (grows by `append`); `:109` `var picked` (ditto); `:124` `var markers` (ditto); `:138` a `map` producing a new array. |
| It allocates **inside the per-frame loop** | `:94` `median(of: Array(flux[lo...hi]))` — a fresh `Array` per flux frame, then `:257-263` `median` calls `values.sorted()`, a second allocation per frame. |
| Its front end is an STFT | `:151-219` `spectralFlux` — 1024-point Hann window at 256 hop (`:34-35`), `vDSP.FFT` **created inside the function** (`:157`), plus six `[Float]` allocations (`:160-170`) before the loop. |
| It needs the whole signal before it can threshold | `:83` `flux.max()`, `:87` a threshold floor scaled by the **global** peak flux, and `:88-95` a moving median over a **±0.175 s two-sided** window — it reads the future. |
| It does blocking file I/O | `:268-309` `readMono` — `AVAudioFile(forReading:)`, a read loop, `mono.reserveCapacity(Int(reader.length))`. |
| It is latency-bound by construction | The two-sided median window and the 1024-sample frame mean a streaming port would carry **≥ ~0.19 s** of lookahead. |

**Conclusion.** Every one of the render-path prohibitions in `CLAUDE.md` and in §6.0.8
(`creative-effects.md:740-745`) is violated by this type by design, and the violations are not
incidental — its algorithm *requires* whole-signal statistics and a two-sided window. Making it
RT-safe is not a refactor; it is a different detector. **This document designs that different
detector, and does not touch `TransientAnalyzer`.** (Nor should the implementer: `:28-31` warns that
any tuning change must bump `analyzerVersion` because `TransientCache` keys the on-disk sidecar cache
on it, and `AudioContentAnalyzer.swift:23` states it is *"reused verbatim (TransientAnalyzer stays
byte-untouched)"*.)

---

## 3. The detector

### 3.1 Shape

Stereo-**linked**, peak-rectified, three one-pole followers, all in the **linear amplitude domain**.
Per frame `n`:

```
peak[n] = max over prepared channels c of |x[c][n]|            (Float → Double)
```

A branching one-pole with independent attack/release coefficients:

```
follow(env, target, cAtk, cRel):
    c   = (target > env) ? cAtk : cRel
    env = c·env + (1 − c)·target
```

Three of them, chained so each reference is a *lag of the fast envelope*, not of the raw peak:

```
envFast     = follow(envFast,     peak[n],  aFastAtk,  aFastRel)     // "the signal"
envAttack   = follow(envAttack,   envFast,  aAttack,   aAttack)      // symmetric lag, τ = attackMs
envSustain  = follow(envSustain,  envFast,  aFastAtk,  aSustain)     // fast up, τ = sustainMs down
```

### 3.2 Coefficient derivation from time constants

Identical convention to `CompressorEffect.swift:181-184` — *"One-pole time constants:
`coeff = e^(−1/(ms·rate))`; the envelope covers 63.2% of a step in exactly attack/release ms"*:

```
a(τ_ms) = exp(−1000 / (τ_ms · sampleRate))          // τ in ms, sampleRate in Hz
aFastAtk = a(fastAttackMs  = 0.05)      // FIXED constant, not a knob
aFastRel = a(fastReleaseMs = 5.0)       // FIXED constant, not a knob
aAttack  = a(attackMs)                  // slot 2, user
aSustain = a(sustainMs)                 // slot 3, user
```

All four are computed in `deriveRenderParams` (the `CompressorEffect.swift:174-185` pattern):
pure libm, no allocation, render-thread-safe, called on generation change **and** from
`storeAutomatedParam`.

### 3.3 The two differentials — taken as dB RATIOS, which is the whole point

```
f = max(envFast,    floorLin)
A = max(envAttack,  floorLin)
S = max(envSustain, floorLin)

dA = max(0, 20·log10(f / A))     // > 0 only while rising faster than its own lag
dS = max(0, 20·log10(S / f))     // > 0 only while falling faster than its own lag
```

⭐ **Why linear followers with a dB ratio, and not dB-domain followers.** A one-pole filtering a
**dB** signal has a step response whose duration depends on where the signal started: from a −180 dB
silence floor (the `max(level, 1e-9)` shape at `CompressorEffect.swift:281`) a τ = 5 ms reference
needs far longer to climb to within 12 dB of a 0 dBFS hit than it does from a −40 dB noise floor. The
"attack window" would then change with *whatever preceded the hit*, which is exactly the kind of
silent, plausible-looking wrongness this tree keeps producing. A **linear** one-pole has a
level-proportional step response, so the **ratio** `f/A` — and therefore `dA` in dB — is invariant
under a change of input gain. **The level-independence comes from the ratio, not from filtering in
dB.** This is a falsifiable claim and §7 leg L6 plants against it.

⭐ **Why each reference lags `envFast` rather than `peak`.** If `envAttack` followed the raw peak with
a slow attack and the *same* release as `envFast`, then during a decay both would fall with the same
coefficient from different values — and the **ratio would be preserved**, so `dA` would never return
to zero after a hit. Lagging `envFast` **symmetrically** (same τ up and down) makes `envAttack`
converge to `envFast` from either side, so `dA → 0` within a few `attackMs` in *any* steady or
decaying passage.

⚠️ **State this precisely, because the over-general version is wrong and I wrote it first.** `dA` is 0
**once `envAttack` has crossed above `envFast`**, not "throughout any decay". After a near-rectangular
onset the crossing is immediate, so `dA` is 0 for the whole tail. After a **slow** onset `envAttack`
converges from *below*, is still below `envFast` when the decay begins, and takes up to ~`attackMs` to
cross — during which `dA > 0` and attack shaping does reach the first part of the decay. That is
musically correct behaviour (a slow swell has a longer "attack" by any definition) but it is **not**
the structural zero the first draft of this section claimed. §7 leg L5(a) measures the crossing, and
its plant breaks it.

### 3.4 Absolute detector floor — noise must not be shaped

```
detectorFloorDb = −70.0        // declared in DAWCore; floorLin = 10^(−70/20) ≈ 3.162e−4
if envFast < floorLin { dA = 0; dS = 0 }                    // hard gate, not just a ratio clamp
if envFast  < 1e-20 { envFast  = 0 }                        // denormal flush — the
if envAttack< 1e-20 { envAttack= 0 }                        // CompressorEffect.swift:279
if envSustain<1e-20 { envSustain=0 }                        // convention, applied to all three
```

Without the hard gate the ratio of two near-zero envelopes is noise, and the unit would apply up to
±20 dB of shaping to a room tone. −70 dBFS is chosen because it is below any musically intended
content and above the float noise floor by a wide margin; it is a **declared constant with one home**
so `fx.describe`'s note and the DSP cannot disagree about it.

### 3.5 The gain law — one home in DAWCore

```swift
// Sources/DAWCore/Effects.swift, inside TransientShaperParams
public static let fullShapeDifferentialDb = 12.0
public static let detectorFloorDb         = -70.0
public static let maxShapeDb              =  24.0
public static let fastAttackMs            =   0.05
public static let fastReleaseMs           =   5.0

/// 0 at no differential, 1 at `fullShapeDifferentialDb` or more. The ONE HOME
/// for what an `attackDb` of +6 actually means.
public static func shapedFraction(differentialDb: Double) -> Double

/// The width, in ms, of the window over which attack shaping is at FULL
/// strength for a step onset. Derived, not asserted: full shaping needs
/// dA >= 12 dB, i.e. A/f <= 10^(-12/20) = 0.2512; for a symmetric lag
/// A(t) = 1 - e^(-t/tau) that holds while t <= tau*ln(1/0.7488) = 0.2893*tau.
public static func attackWindowMs(attackMs: Double) -> Double   // 0.2893 * attackMs
```

Per frame:

```
gainDb = attackDb · shapedFraction(dA)  +  sustainDb · shapedFraction(dS)
gainDb = clamp(gainDb, −maxShapeDb, +maxShapeDb)
g      = pow(10, (gainDb + outputDb) / 20)
out[c][n] = x[c][n] · Float(mixWet·g + mixDry)        // mixWet = mix, mixDry = 1 − mix
```

⭐ **The sustain sign and formulation, stated so it cannot be implemented backwards.** `dS` is
**positive during a decay** (the signal has fallen below its own slow reference), and `sustainDb`
**ADDS** gain proportional to that, saturating at `fullShapeDifferentialDb`. So `sustainDb = +9`
applies up to **+9 dB during the ring-out**, lengthening it; `sustainDb = −9` applies up to −9 dB,
shortening it. ⚠️ **There is a second, equally plausible formulation** — "pull the signal back up
*toward* its slow reference", i.e. `gainDb += min(dS, …)` with no user scalar — and it is **NOT** what
this design specifies: it would make the amount unsettable and give the sustain demo no measurable
number. ⚠️ **The tail does not ring forever at `sustainDb = +9`**, because `envSustain` is itself
decaying, so `dS` saturates and then falls; the audible result is a longer, not an infinite, tail.

⭐ **Bit-exact dry at defaults, by IEEE and not by tolerance.** At `attackDb = sustainDb = outputDb = 0`
and `mix = 1`: `gainDb = 0` regardless of the material, `pow(10, 0) == 1.0` exactly (the property
`CompressorEffect.swift:26-27` already relies on), and `1·1.0 + 0.0 == 1.0`. Multiplying a `Float` by
`1.0f` is the identity. This satisfies rule 6.0.7 (`creative-effects.md:736-739`) and is the
**identity half of the byte gate** in §7.

⚠️ The loop is **never skipped** at `mix == 0`, for the reason `CompressorEffect.swift:310-313` gives
verbatim: the unit is stateful, and an automated `mix 0→1` would snap from stale envelopes.

### 3.6 Cost, stated as an operation count (the wall-clock is UNMEASURED)

Per frame, stereo:

| work | count |
|---|---|
| `fabs` + compare (peak, 2 ch) | 2 + 2 |
| one-pole updates (3 × [1 compare, 2 mul, 1 add]) | ~12 flops |
| divisions | 2 |
| `log10` | 2 |
| `pow` | 1 |
| clamps / compares / the mix multiply-add | ~8 |
| output multiplies | 2 (one per channel) |

**Three transcendental calls per frame.** The shipped `CompressorEffect` already runs **two**
(`:281` `log10`, `:314` `pow`) on every frame of every insert and is in production, so this is the
same order of magnitude as an effect this tree already ships — roughly 1.5× its per-sample
transcendental load. ⚠️ **I have not benchmarked it and I am not quoting a nanosecond figure.** The
first implementation leg should record one; until then the honest statement is *"an operation count
1.5× a shipping effect of the same shape."*

**Memory:** `3 × Double` of envelope state, `4 × Double` of smoothing accumulators, 4 coefficients,
6 derived params. **Nothing that scales with frame count, channel count or sample rate** — which is
what makes `prepare()` allocation-free too (§5).

### 3.7 Latency: ZERO. No lookahead. This is a deliberate refusal.

`var latencySamples: Int { 0 }`, matching every built-in but one. The exception is
`LimiterEffect.swift:267` — `var latencySamples: Int { delaySamples }` — and it is cited here
precisely so the reader sees that the PDC path **exists, works, and is measured sample-exact**
(m25-n), and that this effect is **deliberately not entering it**.

⚠️ **The honest cost of refusing lookahead.** With `fastAttackMs = 0.05` (≈ 2.4 samples at 48 kHz) the
gain reaches ~63 % of its target within ~2 samples and ~95 % within ~7. For a **boost** this softens
the very first two or three samples of the leading edge — inaudible, and it is what SPL's own
zero-latency hardware does. For a **cut** (`attackDb < 0`) the first ~2 samples pass unattenuated,
which is a sub-0.05 ms tick at the onset. **Accepted.** The alternative (§8.2) costs a
`maxLookaheadSamples × maxChannels` ring buffer at `prepare()`, a new declared latency, and a
re-verification of a working guarantee — for two samples.

⛔ **If a future implementer adds lookahead, that is a NEW LATENCY SOURCE and it must declare itself**
in `latencySamples` and be re-measured against the m25-n PDC gate. Do not add it silently.

### 3.8 Parameter smoothing — rule 6.0.6, and where this design deviates

Rule 6 (`creative-effects.md:727-735`) is mandatory and §6.1.3 (`:846-854`) freezes the shape:
interpolate the derived control value per sample across the quantum, recompute coefficients every
**32 frames**.

**What this effect interpolates per sample across the quantum:** `attackDb`, `sustainDb`, `outputDb`,
`mix` — the four values that **multiply the signal directly**. Four accumulators, each stepping from
the previous quantum's value to this quantum's target by `(target − previous)/frameCount` per frame.
This matches `PhaserEffect.swift:75-83` (*"`mix` multiply the signal directly and are interpolated
**per sample**"*).

**What this effect does NOT interpolate, and why — STATED, not inferred.** The four envelope
coefficients (`aFastAtk`, `aFastRel`, `aAttack`, `aSustain`) are recomputed in `deriveRenderParams`
on adopt / automation store only, with **no 32-frame stride and no interpolation**. The reason is a
real difference in kind: `DJFilterEffect` and `PhaserEffect` interpolate **filter coefficients in the
audio path**, where a step changes the *output* discontinuously. A one-pole envelope coefficient
changes the *trajectory* of a state variable whose current value is unchanged — the envelope is
continuous across the step, so there is nothing to zipper. `CompressorEffect.swift:183-184` already
recomputes `attackCoeff`/`releaseCoeff` exactly this way, per adopt, and ships. **This is a
deliberate, narrow deviation from §6.1.3 and it is recorded here so nobody has to infer it.**

⛔ **m39-j proved that mandatory smoothing was deletable with 24/24 tests green**
(`ROADMAP.md:4173-4176`). Leg L8 in §7 exists for that reason and carries its own plant.

---

## 4. The parameter table — ORDER IS FROZEN, APPEND-ONLY FOREVER

Rule 6.0.1 (`creative-effects.md:705-710`): *"Position in `EffectParamSpec.specs(for:)` **is** the
automation slot (`storeAutomatedParam(slot:value:)`). Inserting a param in the middle silently
re-points every saved automation lane on that effect."* Shape and init signature read at
`Sources/DAWCore/Effects.swift:2712-2721`; `curve` and `modulatable` have **no defaults** by design
(`:2684-2686`, `:2701-2705`).

| slot | name | range | default | unit | curve | Modulatable | beginner label |
|---:|---|---|---:|---|---|---|---|
| **0** | `attackDb` | −20 … 20 | **0** | dB | **`.linear`** | **yes** | **Punch** — how much more (or less) of the hit at the front of each sound |
| **1** | `sustainDb` | −20 … 20 | **0** | dB | **`.linear`** | **yes** | **Body** — how much more (or less) of the ring-out after the hit |
| **2** | `attackMs` | 0.1 … 50 | **5** | ms | `.logarithmic` | **yes** | **Punch Length** — how long the front of a sound counts as "the hit" |
| **3** | `sustainMs` | 20 … 1000 | **200** | ms | `.logarithmic` | **yes** | **Body Length** — how far into the tail the effect keeps working |
| **4** | `outputDb` | −24 … 24 | **0** | dB | **`.linear`** | **yes** | **Output Trim** — level match, so you compare punch and not loudness |
| **5** | `mix` | 0 … 1 | **1** | linear | **`.linear`** | **yes** | **Mix** — blend the shaped sound back with the untouched one |

**Totals contributed: 6 yes, 0 warned, 0 refused.**

### 4.1 Why each `curve` is what it is (rule 6.0.2)

- `attackDb`, `sustainDb`, `outputDb`: ranges **cross 0**. `.logarithmic`/`.decibel` **require
  `lo > 0`** — `ParamCurveConformanceTests`' `multiplicativeCurvesHaveAPositiveLowerBound` asserts it
  and the runtime fallback to linear is **silent** (`creative-effects.md:713-715`). `.linear` is
  **forced**, not chosen.
- `mix`: range **touches 0**. `.linear`, same rule, same force.
- `attackMs` (0.1 … 50, `lo > 0` ✓) and `sustainMs` (20 … 1000, `lo > 0` ✓): `.logarithmic` is both
  legal and correct — `attackMs` spans ~9 octaves and the musically useful third of it lives under
  5 ms, which a linear taper would bury in the first tenth of the knob.

### 4.2 Why every verdict is `yes` — a judgement, not an omission

Rule 6.0.3 requires a verdict per param and rule 6.0.5 makes discrete params automatically `refused`.
**This kind has no discrete params, deliberately** (see §8, rejected alternatives 6 and 7). The four
multiplicative params are `yes` because they are interpolated per sample (§3.8). The two time
constants are `yes` because a coefficient change bends a continuous state variable's trajectory
without moving its value — unlike `eq`, which is `warned` because its *filter* coefficients zipper
(`creative-effects.md:734-735`).

### 4.3 The §6.2 totals test MUST be updated — and the design doc's own figure is STALE

Rule 6.0.4 pins the verdict split. ⚠️ **`creative-effects.md:719-722` says "31 yes / 18 warned /
15 refused = 64 across 11 kinds". That is stale.** The live pin is
`Tests/DAWCoreTests/ModulationTests.swift:46`:

> `@Test("§6.2 frozen verdict split: 74 yes + 20 warned + 19 refused = 113 across all 18 param-bearing kinds")`

Adding this kind takes it to **80 yes + 20 warned + 19 refused = 119 across 19 param-bearing kinds**.
**The test's title string is itself a site** — update the string as well as the numbers, or the test
name will lie about what it pins.

### 4.4 No reserved slots

Rule 6.0.1's corollary (`creative-effects.md:708-710`): *"never reserve a slot… a reserved-but-inert
param buys an ordering that was never at risk and puts a lie in `fx.describe`."* Nothing below slot 5
is reserved. A future `lookahead`, `detectMode` or `stereoLink` **appends at slot 6+**, which is
always safe.

### 4.5 Draft `note:` strings — because a spec arm in this codebase is ~60% teaching text

Every sibling arm I read is mostly `note:` (`.phaser`'s runs `Effects.swift:3873-3969`). Leaving six
notes to be written cold is how the one fact that makes `attackDb` honest gets lost. Two drafts, in
the house voice; the implementer writes the other four to match.

**Slot 0, `attackDb`** — the note that must exist, because the range alone is a lie without it:

> How much louder or quieter to make the FRONT of each sound - the stick hitting the drum, the pick
> hitting the string - without touching the rest of it. Positive adds punch and makes a kit sound
> closer and more aggressive; negative rounds the hit off and pushes it back into the room, which is
> the fastest way to tame a clicky kick or an over-close snare. ⭐ THE NUMBER IS A MAXIMUM, NOT A
> PROMISE: +6 means "up to +6 dB", and the full amount only lands on a hit whose start is at least 12
> dB louder than its own running average (`fullShapeDifferentialDb`, reported in every fx.add and
> fx.setParam RESULT). A soft, slow-swelling sound has a smaller difference and gets proportionally
> less - which is what makes this feel natural rather than pumping. It works at ANY fader level: the
> detector compares the sound to ITSELF, so turning the track down does not turn the effect down.
> ⚠️ LEVEL WARNING, because it is real and not a mixing choice: a positive setting RAISES PEAKS, so
> check your headroom or trim it back with `outputDb`. Nothing happens at all below -70 dBFS
> (`detectorFloorDb`) - that is deliberate, so room tone and noise are never shaped. The curve is
> linear because the range crosses 0 and a logarithmic taper cannot.

**Slot 2, `attackMs`** — the note that stops the commonest wrong reading (*"this is a fade time"*):

> How long the FRONT of a sound lasts, as far as this effect is concerned - not a fade time and not a
> delay. It sets how quickly the effect stops treating a sound as "still starting". SHORT (0.1-3 ms)
> catches only the very tip: the click of a kick beater, the snap of a snare's stick. MEDIUM (5 ms,
> the default) is the body of a drum hit and suits a whole loop. LONG (20-50 ms) reaches into plucks
> and piano notes, where the "attack" genuinely is that long. ⭐ The window over which the boost is at
> FULL strength is about 0.29 times this number - so 5 ms gives roughly 1.4 ms of full punch, and 30
> ms gives about 8.7 ms. You do not have to work that out: it is reported as `attackWindowMs` in
> every fx.add and fx.setParam RESULT. Too long and the effect stops sounding like punch and starts
> sounding like a volume ride; too short and it only sharpens the click without adding weight. The
> curve is logarithmic because the useful range spans nine octaves and most of what you want lives
> under 5 ms, which a linear knob would bury in its first tenth.

⚠️ **Do NOT claim in any note that `fx.describe` reports `attackWindowMs`** — it does not; §10.2.
Name the tool that actually carries it (`fx.add` / `fx.setParam` results, and `project.snapshot`).
`ROADMAP.md:4410-4414` records this exact false claim shipping in three places at once.

---

## 5. Where memory is allocated — the RT-safety statement

| what | where | when |
|---|---|---|
| `paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>` | `init` | once, off the render thread (`CompressorEffect.swift:90-91`) |
| `ParamSnapshot` boxes (immutable POD payload) | `@MainActor apply(params:)` | on parameter change only, with the ≥ 1 s retire bin (`CompressorEffect.swift:119-131`) |
| envelope state (3 `Double`), smoothing accumulators (4 `Double`), coefficients (4 `Double`), derived params (6 `Double`) | **stored properties of the class** | at `init`; `prepare()` only **zeroes** them |
| channel-pointer gather | `InlineChannelPointers` — fixed-size stack struct, `CompressorEffect.swift:328-362` | per quantum, **stack only** |
| **the render path** | — | **NOTHING. No buffer, no ring, no array.** |

`prepare(sampleRate:maxFramesPerQuantum:channelCount:)` therefore allocates **nothing either** — it
stores the rate, clamps `preparedChannels` to `min(channelCount, maxChannels = 8)`, zeroes the three
envelopes and the four accumulators, and sets `lastGeneration = .max` to force a coefficient re-derive
at the new rate (`CompressorEffect.swift:135-145`). ⭐ **The absence of any prepared buffer is the
direct consequence of refusing lookahead** (§3.7): a lookahead design would need
`maxLookaheadSamples × maxChannels` Floats here, and that is the contrast that makes zero-latency
worth its two-sample softening.

⚠️ **Render-path loops are `while`, not `for i in 0..<n`** — rule 6.0.8
(`creative-effects.md:743-745`): a `Range` iteration raises ~2 malloc/free events *per iteration* at
`-Onone`, measured at `EffectChainProcessor.swift:402-412`. `PhaserEffect.swift:442-443` is the
current idiom (`var frame = 0` / `while frame < minFrames`). ⚠️ `CompressorEffect.swift:260` uses
`for frame in 0..<minFrames` — it **predates the rule**; do not copy that line.

---

## 6. Every site that must change — enumerated, with what I verified

Positive-controlled census: `grep -rl "phaser\|Phaser"` over
`Sources Tests mcp-server/src claude-plugin docs/ARCHITECTURE.md mcp-server/README.md` returns
**33 files**; the same command shape on `bitCrusher` returns **44** (older, used as a fixture in more
tests). The grep works and 33 is a count, not a coincidence. ⚠️ Per `creative-effects.md:1462-1463`,
**33 is not the cost** — most are fixtures or prose. The cost is the list below.

### 6.A Compiler-forced — the build stops until you do these

| # | file:line (of the `.phaser` sibling) | what |
|---:|---|---|
| A1 | `Sources/DAWCore/Effects.swift:154` | the `case transientShaper` in `enum Kind` (`:8`), appended **after** `.phaser`, **before** `.audioUnit` (`:156`) |
| A2 | `Sources/DAWCore/Effects.swift` (new, near `PhaserParams`, ~`:2600-2667`) | the `TransientShaperParams` struct + the §3.5 statics + a clamping `init` + `decodeIfPresent ?? default` decoding (the `ChorusParams` pattern, `:756-762`) |
| A3 | `Sources/DAWCore/Effects.swift:179` | `public var transientShaper: TransientShaperParams?` on `EffectDescriptor` |
| A4 | `Sources/DAWCore/Effects.swift:214` | `public var resolvedTransientShaper: TransientShaperParams { transientShaper ?? TransientShaperParams() }` |
| A5 | `Sources/DAWCore/Effects.swift:237` | the `init` parameter — ⚠️ **`= nil` defaulted, like `phaser: PhaserParams? = nil` at `:237`. This does NOT force call sites.** See B7. |
| A6 | `Sources/DAWCore/Effects.swift:3871` → new arm | `EffectParamSpec.specs(for:)` (`:2724`). **Verified exhaustive**: `.audioUnit` arm at `:4003`, no `default:` |
| A7 | `Sources/DAWCore/Effects.swift:4225` → new arm | `paramValue(named:)`. **Verified exhaustive**: `.audioUnit` at `:4237`, closes `:4239`, no outer `default:` (the *inner* name switch has `default: return nil`, which is correct) |
| A8 | `Sources/DAWEngine/Effects/EffectFactory.swift:60` and `:108` | `makeInstance(for:)` + `applyParams(_:to:)`. Both exhaustive (`.audioUnit` last, `:62` / `:110`) |
| A9 | `Sources/DAWCore/ProjectStore.swift:3894-3909` → new arm | `applyEffectParam`. **Verified exhaustive**: `.audioUnit` at `:3910`, closes `:3915` |
| A10 | `Sources/DAWControl/Commands.swift:10690` → new arm | `effectParamsJSON` (`:10450`). **Verified exhaustive**: `.audioUnit` at `:10718`, closes `:10729` |
| A11 | `Sources/DAWAppKit/EffectHonestyNote.swift:81-87` | `note(for:)` — **exhaustive on purpose**, and it says so at `:78-79`: *"a new `Effect.Kind` stops the build here and its author has to decide whether the effect promises revelation."* Decide deliberately (my read: it does **not** promise revelation — it promises punch and delivers punch — so it joins the grouped nil arm at `:85-87`) |
| A12 | `Sources/DAWAppKit/EffectEditorModel.swift:343` → new arm | the editor's param grouping. **Verified exhaustive**: `.audioUnit` at `:357` |
| A13 | `Sources/DAWAppKit/MixerModel.swift:118` → new arm | `effectDisplayName`. **Verified exhaustive**: `.audioUnit` at `:119` (read at `:100-124`) |

### 6.B Hand-written — the compiler is SILENT. This is where the kind dies quietly.

⛔ **The six persistence sites in `Sources/DAWCore/ProjectDocument.swift`**, all six located by
grepping `phaser` in that file and all six read:

| # | `ProjectDocument.swift` line | what | failure if omitted |
|---:|---:|---|---|
| B1 | **760** | `public var phaser: PhaserParams?` — the stored property | the field does not exist to carry |
| B2 | **773** | `case djFilter, ringMod, flanger, hallReverb, tapeDelay, stereoWidth, phaser` — the `CodingKeys` case | **never written to disk** |
| B3 | **802** | `phaser = effect.phaser` — init-from-effect | **the mirror is built empty**; saves as default |
| B4 | **829** | `phaser = try c.decodeIfPresent(PhaserParams.self, forKey: .phaser)` | **loads back as default** — saved fine, silently lost on open |
| B5 | **859** | `try c.encodeIfPresent(phaser, forKey: .phaser)` | **never written to disk** |
| B6 | **881** | `phaser: phaser,` — the rebuild call into `EffectDescriptor.init` | **round-trips to default** |

⭐⭐ **B7 IS A SEVENTH SITE OF THE SAME SHAPE AND IT IS NOT IN THE BRIEF. I found it and verified it.**

| # | file:line | what | failure if omitted |
|---:|---|---|---|
| **B7** | **`Sources/DAWCore/MixerPresets.swift:62`** | `EffectDescriptor.withFreshID()` (`:41-63`) rebuilds the descriptor **field by field** — `phaser: phaser,` sits at `:62`, `audioUnit: audioUnit)` at `:63` | A mixer preset containing a `.transientShaper` **loses every parameter** when stamped onto a strip. The user sees the right kind with default values. |

**Why the compiler cannot catch B6 or B7:** `EffectDescriptor.init`'s params are all defaulted —
verified at `Sources/DAWCore/Effects.swift:236-237` (`stereoWidth: StereoWidthParams? = nil`,
`phaser: PhaserParams? = nil`). A call site that omits the new argument **compiles cleanly and
silently drops it**. This is the exact failure the brief warned about, in a file the brief did not
name.

⭐ **B8 IS AN EIGHTH SITE, also compiler-silent, also verified.**

| # | file:line | what | failure if omitted |
|---:|---|---|---|
| **B8** | **`Sources/DAWCore/ProjectStore.swift:3262`** | the kind display-name switch **has a `default:` arm** (read at `:3255-3264`): `default: return kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()` | Ships silently as **"TransientShaper"** instead of **"Transient Shaper"** — every sibling from `:3255-3261` spells itself out. A cosmetic-looking bug that the compiler, `effect-kind-surface.mjs` (whole-file presence) and every test will pass. |

**The remaining hand-written surfaces:**

| # | file:line | what |
|---:|---|---|
| B9 | `Sources/DAWApp/Mixer/MixerStripView.swift:11-14` | `addableEffectKinds` — self-documented at `:8-10` as *"HAND-MAINTAINED, not `Kind.allCases` — a new built-in kind is INVISIBLE in the '+' menu until it is appended here."* **This is the only way a human can add the effect.** |
| B10 | `Sources/DAWControl/CopilotCatalog.swift:999` | the kind list. **RULED YES for a new effect KIND** by `creative-effects.md:1465-1476` §11.0.1. Pinned by `Tests/DAWControlTests/CopilotCatalogTests.swift:142-152` (`Kind.allCases`-derived), so this one *will* redden — good. |
| B11 | `Sources/DAWCore/MediaImporting.swift:604` | the master-chain refusal string's hand-written `gain\|eq\|…\|phaser` kind list |
| B12 | `Sources/DAWEngine/Effects/EffectRendering.swift:174-175` | the per-kind render-cost ledger in the doc comment — add the transient shaper's 3-transcendental-per-frame row |
| B13 | `mcp-server/src/server.ts:4284-4304` | `fxKindSchema`'s `z.enum([...])` — append `"transientShaper"` **after `"phaser"`, before `"audioUnit"`**. See §9. |
| B14 | `mcp-server/src/server.ts:4305+` | the `.describe(...)` prose on the same schema. See §9 — **this text is SHARED**. |
| B15 | `mcp-server/README.md` | the `fx_add` kind list and the `fx_describe` per-kind gloss (a gated surface, `effect-kind-surface.mjs:46-47`) |
| B16 | `claude-plugin/agents/sound-designer.md` | description **and** body (a gated surface, `effect-kind-surface.mjs:37-38`) |
| B17 | `claude-plugin/skills/daw-wire-reference/SKILL.md` | ⚠️ deliberately **NOT** a gated surface (`effect-kind-surface.mjs:39-45`: it is *"17 sections of TRAPS, not an enumeration"*). Add an entry only if this kind has a trap. **It does: the detector floor at −70 dBFS, and the fact that `attackDb` is a *maximum* reached only at a full differential.** |
| B18 | `docs/ARCHITECTURE.md` | kind list **and** the "Wire surface — CURRENT TOTALS" ledger, which `creative-effects.md:1453` records as already four closes stale (reads 204/209 against a measured 218/223). ⛔ **This document does not touch it** — the implementer does. |
| B19 | `docs/ROADMAP.md` | tick the item. ⛔ Orchestrator's file. |
| B20 | `CHANGELOG.md` | the entry. |
| B21 | `claude-plugin/server/index.mjs:46092` | ⚠️ **GENERATED** (the bundled MCP server; the `fxKindSchema` enum is inlined there). Do **not** hand-edit — regenerate via `/plugin update` and **stdio-verify with a negative control** before announcing. A bundle in this tree once went 18 days stale. |

### 6.C New files

- `Sources/DAWEngine/Effects/TransientShaperEffect.swift` — the DSP
- `Tests/DAWEngineTests/TransientShaperTests.swift` — L3–L9 below
- `Tests/DAWCoreTests/TransientShaperParamsTests.swift` — clamping, the `shapedFraction` /
  `attackWindowMs` laws (the `Tests/DAWCoreTests/PhaserParamsTests.swift` sibling)
- `scripts/demos/specs/transient-shaper-attack.json` and `…-sustain.json` — §7.4
- `scripts/gates/m39y-transient-shaper-bytes.mjs` — §7.3

### 6.D Existing tests that must be extended (each will fail loudly until it is)

| file:line | what |
|---|---|
| `Tests/DAWCoreTests/ModulationTests.swift:46` | the `@Test(...)` **title string** and the totals → 80/20/19 = 119 across 19 |
| `Tests/DAWControlTests/FXCommandTests.swift:727-734` | the `expectedParam` census map — add `"transientShaper": "attackDb"` |
| `Tests/DAWControlTests/FXCommandTests.swift:740` | `#expect(censusKinds.count >= 18)` → `>= 19` (the non-vacuity guard) |
| `Tests/DAWControlTests/FXCommandTests.swift:705` | the expected `fx.add` unknown-kind error string, which enumerates every kind |
| `Tests/DAWCoreTests/ParamCurveConformanceTests.swift` | curve conformance over the new table |
| `Tests/DAWCoreTests/EffectDocumentMirrorTests.swift` | the six + two hand sites (§7 leg L10) |
| `Tests/DAWCoreTests/PersistenceTests.swift` | project round-trip |
| `Tests/DAWAppKitTests/InsertLabelBudgetTests.swift` | "Transient Shaper" against the strip's label budget — ⚠️ it is the **longest** built-in name yet (15 chars + space vs "Bass Enhancer" 13); check before assuming it fits |
| `Tests/DAWControlTests/CopilotCatalogTests.swift:142-152` | `Kind.allCases`-derived; will redden until B10 lands |
| `Tests/DAWCoreTests/MasterChainStoreTests.swift`, `Tests/DAWControlTests/MasterChainCommandTests.swift` | master-chain kind acceptance |

---

## 7. The verification plan

This project's characteristic failure is *"things fail silently by returning something that LOOKS LIKE
A VALID ANSWER"* — `.modulation` shipped **inert with 24 green unit tests** and was caught only by a
byte-identity guard in a demo harness. **Every leg below names the plant that must redden it.** A leg
with no plant is not a leg.

### 7.1 ⛔ The harness's own byte check is a WARNING, not a gate. Measured.

`scripts/demos/render-variants.mjs:637-642` computes per-variant sha256 and, on a collision, prints
`⚠ WARNING: N variant(s) rendered BYTE-IDENTICAL…` — via `console.error`, with **no `process.exit`**.
The only thing that sets a non-zero exit is `:788`:

```js
process.exit(anyRenderFailed || anyInaudible ? 1 : 0);
```

⛔ **Therefore: running `render-variants.mjs` and seeing exit 0 does NOT prove the effect did
anything.** That is precisely the "green that cannot fail" shape. The byte gate must be a **separate
script that asserts and exits**, consuming `manifest.json` (written at `:780-781`, per-variant
`sha256` at `:761`).

### 7.2 Unit legs, each with its plant

| leg | assertion | ⛔ plant that must redden it |
|---|---|---|
| **L1** | `TransientShaperParams.init` clamps every field to its declared range; a partial JSON object decodes with per-field defaults | widen `attackRange` to `-40...40` → an out-of-range value survives |
| **L2** | `specs(for: .transientShaper)` returns exactly 6 specs, **in the frozen order**, with the declared ranges/defaults/units/curves/verdicts | swap slots 0 and 1 → the order assertion reddens (this leg is what makes the wire contract enforceable) |
| **L3 — detector step response** | Feed a unit step. `dA` exceeds 12 dB within `fastAttackMs·3` and falls below 0.5 dB within `4·attackMs`. `dS` is 0 during the step and exceeds 12 dB within `sustainMs` of the step's end | point `envAttack`'s attack coefficient at `aFastAtk` (making it identical to `envFast`) → `dA ≡ 0` → reddens |
| **L4 — bit-exact dry at defaults** | Render 4 000 frames of pink-ish content at all defaults; assert the output `Float` **bit patterns** are identical to the input's, sample for sample (not a tolerance) | change `attackDb`'s default from `0` to `0.001` → reddens. ⭐ Second plant: replace `mixWet·g + mixDry` with `g` alone → must **stay green** at `mix = 1` (proving the fold is an identity there) but redden L-mix below |
| **L5 — independence, which IS the effect's definition** | (a) `attackDb +9, sustainDb 0`: the window `[onset+50 ms, onset+200 ms]` is within **±0.5 dB** of the all-default render. (b) `sustainDb −9, attackDb 0`: the window `[onset, onset+attackWindowMs]` is within **±0.5 dB** of the all-default render | ⛔⛔ **EACH PLANT MUST REACH THE OUTPUT THROUGH A NON-ZERO MULTIPLIER IN THAT LEG'S OWN SETTINGS — see §7.2.1, where the first draft of this row got it wrong twice.** (a) make `envAttack` follow **`peak`** instead of `envFast` (slow attack, `envFast`'s release) — the formulation §3.3 rejects, where the ratio is *preserved* through a decay so `dA` never returns to 0 → the +9 dB attack boost leaks into `[50, 200] ms` → reddens. (b) make `dS` divide by **`envAttack`** instead of `envFast` — `dS = max(0, 20log10(S/A))` — so at onset `A ≈ 0` while `S ≈ f`, `dS` saturates, and the −9 dB sustain cut lands squarely in the attack window → reddens |
| **L6 — LEVEL INDEPENDENCE (the detector's central claim)** | The same burst rendered at −6 dBFS and at −26 dBFS produces gain trajectories agreeing within **0.1 dB** at every sample | ⭐ **replace the dB ratio with a linear difference** — `dA = envFast − envAttack` — the classic wrong formulation. The shaping becomes level-dependent and the leg reddens. This plant falsifies §3.3 directly and is the most important one in the table |
| **L7 — allocation-free** | Copy `Tests/DAWEngineTests/PhaserTests.swift:1066` `processIsAllocationFree` **and its anti-vacuity partner at `:1144` `theAllocationProbeCanSeeAnAllocation`** — 4 000 quanta of 512 frames, `malloc_logger` hook (`:1053-1063`), zero events, `Issue.record` (not skip) if `malloc_logger` is unavailable (`:1067-1069`) | rewrite the inner loop as `for frame in 0..<minFrames` → non-zero malloc events at `-Onone` (rule 6.0.8, `EffectChainProcessor.swift:402-412`). ⚠️ **Re-stage the input buffer every call** — `PhaserTests.swift:1096-1107` records a run where feedback drove the render to NaN while the allocation count stayed a clean 0; a probe measuring NaN is measuring nothing |
| **L8 — smoothing is not deletable** | Automate `attackDb` 0 → 12 at a quantum boundary mid-render; assert `max|g[n] − g[n−1]|` over the boundary is bounded by the per-sample interpolation step | delete the interpolation and use the target directly → the single-sample jump exceeds the bound. ⛔ **This leg exists because `ROADMAP.md:4173-4176` records mandatory smoothing being deletable with 24/24 green** |
| **L9 — latency** | `latencySamples == 0`, **and** inserting this effect into a chain leaves `EffectChainProcessor.latencySamples` (`:600-604`) unchanged | return `64` → the chain total moves → reddens. This is what keeps the m25-n PDC guarantee honest |
| **L10 — all EIGHT persistence sites** | Save a project with a non-default `.transientShaper`, reload, assert **every one of the 6 params** survives. Separately: build a `MixerPreset` containing one, call `freshChain()` (`MixerPresets.swift:35`), assert params survive | ⛔ **Eight separate plants, one per site.** Comment out B3 (`transientShaper = effect.transientShaper`) → round-trip reddens. Comment out B5 (`encodeIfPresent`) → reddens. Comment out **B7** (`MixerPresets.swift:62`) → **only the preset leg reddens**, which is why it needs its own leg. ⭐ Positive-control the whole count by running the same eight-site check against `phaser`, which is known-good |
| **L11 — census, driven from `allCases`** | Extend `FXCommandTests.swift:727-742`. ⛔ **The map is driven by `EffectDescriptor.Kind.allCases` (`:735`) and a kind with no entry FAILS rather than being skipped (`:741-742`) — that structure is why `.tapeDelay` was caught in 2026-09-19 after a hand-written list had silently lost it (`:716-724`). Never replace it with a literal array.** Bump the non-vacuity floor at `:740` to `>= 19` | delete the `"transientShaper"` entry from `expectedParam` → the `uncovered` assertion reddens by name |
| **L12 — surface presence** | `node scripts/gates/effect-kind-surface.mjs` exits 0 across all 5 surfaces (`:36-54`) | `GATE_SELFTEST_EXTRA_KIND=notAKind node scripts/gates/effect-kind-surface.mjs` must **exit 3** with "SELF-TEST DID NOT FIRE" absent, i.e. it must redden all 5 (`:88-89`, `:159-165`). ⚠️ **This gate is whole-file PRESENCE only** (`:13-21`) — it cannot see that a kind reached 5 of the 8 hand sites in §6.B, and it **cannot see B7 or B8 at all** since `MixerPresets.swift` and the display-name switch are not surfaces. L10 and a display-name assertion are the only instruments for those |
| **L13 — wire count unmoved** | `node scripts/gates/doc-count-drift.mjs` exits 0 with the command total **unchanged at 227**. Rule 6.0.11 (`creative-effects.md:754-759`): a new kind needs **no new verb**; *"if a `doc-count-drift` run after these items reports a changed command count, something was added that this contract did not authorise"* | the gate self-positive-controls and exits 3 without scoring if its control fails — trust exit 3 as a NON-pass |

### 7.2.1 ⛔⛔ THE PLANT RULE, because I violated it in this document's own first draft

**A plant is only a plant if the quantity it corrupts reaches the output through a NON-ZERO
multiplier under that leg's own settings.**

L5(a) sets `sustainDb = 0`; L5(b) sets `attackDb = 0`. The first draft of the L5 row planted on `dS`
for leg (a) and on `dA` for leg (b) — in each case the corrupted term is multiplied by the zeroed
amount (`gainDb = attackDb·shapedFraction(dA) + sustainDb·shapedFraction(dS)`), so **both plants would
have left both legs green** and the independence gate would have been unfalsifiable while reading as
rigorous. That is this tree's named characteristic failure, reproduced inside the very table written to
prevent it. It was caught in review, not by any check.

⛔ **Before accepting any leg in §7.2, trace its planted quantity to the output under that leg's exact
settings and confirm the path is not multiplied by zero.** Then run the plant and record the redness.
A plant that has never been run is indistinguishable from one that cannot fire.

### 7.3 ⛔ The byte-identity render gate — `scripts/gates/m39y-transient-shaper-bytes.mjs`

Reads `scripts/demos/out/transient-shaper-attack/manifest.json`.

**Self-control first (exit 3, NOT a pass, if any fails):** the manifest parses; it has ≥ 4 variants;
every variant has `ok === true`; every variant has a non-null 40+-char `sha256`. A gate that cannot
read its own input must not report an all-clear — the `effect-kind-surface.mjs:91-100` convention.

**Then two assertions, both exiting 1 on failure:**

1. **IDENTITY.** `sha256("no-shaper") === sha256("shaper-default")`.
   The effect at its defaults must render **byte-identical** to no effect at all (§3.5).
2. **DIFFERENCE.** `sha256("attack-plus-9")`, `sha256("attack-minus-9")` and `sha256("no-shaper")` are
   **three distinct** hashes.

⚠️⚠️ **`render-variants.mjs` WILL PRINT `⚠ WARNING: 1 variant(s) rendered BYTE-IDENTICAL to another`
for the identity pair. That warning is EXPECTED and CORRECT. Do not "fix" it, do not perturb the
default to silence it.** It is `:639-642` doing its job on a pair that is *supposed* to collide, and
it does not affect `:788`'s exit code.

**Plants (both must be run, and the run recorded):**

- ⛔ **(a) redden IDENTITY:** make `g` at defaults `pow(10, 1e-7/20)` instead of exactly 1. The two
  hashes diverge. *If this plant does not redden, the gate is comparing the wrong files.*
- ⛔ **(b) redden DIFFERENCE:** force `shapedFraction(differentialDb:)` to `return 0`. All four
  variants collapse to identical bytes. *This is the m39-e inert-effect shape, and this plant is the
  only thing that proves the gate can see it.*

### 7.4 The demo sets — §9 obligation, and the material ruling that decides whether it works

⛔ **Per `creative-effects.md:1315-1319` §9.5: the item is not done until the harness has exited 0 on
its demo set.** Per the user's standing listening rule and §9.1: **3–4 variants differing on ONE axis**.

**Two sets, because the two axes being independent IS the product.**

`scripts/demos/specs/transient-shaper-attack.json` — axis `attackDb`:

| variant | role | setting |
|---|---|---|
| `no-shaper` | baseline | no effect at all (the `phaser.json` convention — *"Variant 1 has no effect at all"*) |
| `shaper-default` | identity control | effect added, **every param at default** |
| `attack-plus-9` | | `attackDb: +9` |
| `attack-minus-9` | | `attackDb: −9` |

`scripts/demos/specs/transient-shaper-sustain.json` — the same four on `sustainDb`.
Every other parameter byte-identical across all variants within a set.

⭐⭐ **THE MATERIAL RULING — this is the single most likely way this demo gets built wrong, and it is
the exact shape of `creative-effects.md:1286-1288`'s reverb warning.** §9.2 (`:1281-1290`) prescribes
a **saw pad** for filter/ring-mod/flanger demos. ⛔ **A pad is the worst possible source for this
effect.** A transient shaper acts only where `dA` or `dS` is non-zero; a sustained pad has no onsets
and no decays, so **every variant would render nearly identical and the demo would prove nothing while
exiting 0.** **Frozen for this kind: percussive or staccato material with clear onsets and audible
decay into silence** — a drum loop (reachable now via the pad grid / `clip.sliceToSampler`, shipped as
`m39-pads`) or a plucked staccato phrase. This is the same decision §9.2 already made for reverb, for
the same reason, and it belongs in `creative-effects.md` §9.2 as a fifth bullet.

⚠️ **§9.3's loudness confound (`:1292-1302`) points straight at this effect, and the resolution is
`outputDb`.** `attackDb +9` genuinely raises integrated loudness; §9.3 **freezes** every variant to
within **1.0 LU** of the set's median. Those two facts are only compatible because of slot 4: trim
each variant with `outputDb` until the integrated loudness matches, and **the shaping survives
untouched** — a transient shaper changes the **crest factor**, and crest factor is exactly what
loudness matching does *not* normalise away. ⭐ **This makes `outputDb` load-bearing for the demo
obligation, not a nicety**, and it is the reason it occupies a permanent slot. Measure with
`ffmpeg -hide_banner` — ⚠️ `-v error` **suppresses** `ebur128` and `astats`, which log at INFO, so the
numbers vanish while the command looks like it succeeded.

**The §9.4 listening note (novice language), shipped with the attack set:**

> Listen to the very front of each drum hit, not the whole loop. In `attack-plus-9` the stick or
> beater is more *there* — the hit pokes out of the loop and the space after it sounds a touch wider.
> In `attack-minus-9` the same hits are rounder and further back, as if the room swallowed the front
> of them. **These are levelled to the same loudness on purpose**, so if one just sounds "bigger" you
> are hearing the punch, not the volume. **If you hear no difference at all, check the material has
> real hits in it** — this effect works on the *start* of sounds, so on a smooth pad or a held chord
> it genuinely does nothing, and that is not a fault.

### 7.5 The measurable acceptance number

⛔ **The fixture is NOT a Dirac click, and the reason is structural.** Zero lookahead means the gain
rises *after* the leading edge (§3.7). A one-sample click is over before any boost lands, so a
click-train measurement would read ≈ 0 dB at `attackDb +6` and an implementer would conclude the
effect is inert when it is working correctly. **That is this tree's characteristic failure in fixture
form.**

**Fixture** — `TransientShaperTests`, synthesised in-test so it is exact and deterministic:

> 1 kHz sine, **20 ms on** with a 5 ms exponential decay tail, repeated every **250 ms**, 8 bursts,
> peak **−12 dBFS**, 48 kHz stereo (identical L/R, so the stereo link is unambiguous).

**Settings** — `attackMs = 30` (not the 5 ms default), `sustainDb = 0`, `outputDb = 0`, `mix = 1`.

**Why 30 ms:** `attackWindowMs(30) = 0.2893 × 30 = 8.68 ms` (§3.5). At the 5 ms default the full-shaping
window is only **1.45 ms**, which is too narrow to window cleanly with ffmpeg and would make the
measurement a test of window alignment rather than of the effect. **This is stated in the test header
so nobody "corrects" the fixture back to the default and then reports a failure.**

| measurement | window, relative to each burst onset | expected | tolerance |
|---|---|---|---|
| **A1 — attack boost lands** | `[0, 8.68 ms]`, peak | **+6.00 dB** vs the same render at `attackDb = 0` | **± 0.5 dB** |
| **A2 — attack cut lands** | `[0, 8.68 ms]`, peak | **−6.00 dB** at `attackDb = −6` | **± 0.5 dB** |
| **A3 — independence** | `[50 ms, 200 ms]`, peak | **0.00 dB** vs `attackDb = 0` | **± 0.5 dB** |
| **A4 — level independence (L6)** | whole file | the per-sample gain trajectory at −12 dBFS and at −32 dBFS peak | **± 0.1 dB** |

**Why A3's window starts at 50 ms:** `dA` is clamped to 0 during any decay because `envAttack` sits
*above* `envFast` after a fast onset (§3.3), and the fixture's onset is rectangular, so the crossing
is immediate and `dA` is 0 from ~25 ms onward. ⚠️ **On a slow onset the crossing can take up to
`attackMs`** — 50 ms is a conservative margin past both the burst end (25 ms) and `attackMs` (30 ms),
chosen so the leg does not depend on the fast-onset special case it happens to be measuring.

**Why ±0.5 dB:** the window edge is not sample-aligned to the gain trajectory, and `envFast`'s 0.05 ms
attack means the first ~2 samples carry less than full gain. Both are sub-0.1 dB effects on a peak
measurement; 0.5 dB is 5× headroom and still 12× tighter than the 6 dB the leg is measuring.

**The ffmpeg cross-check, on the rendered demo files** (a second instrument, because
`CLAUDE.md` is right that two instruments disagreeing is the signal):

```
ffmpeg -hide_banner -i <variant>.wav -af astats=metadata=1:reset=0 -f null -      # peak / RMS / crest
ffmpeg -hide_banner -i <variant>.wav -af ebur128=peak=true -f null -              # integrated LUFS, for the §9.3 match
```

⭐ **The strongest single number, and the one to report:** `astats`' **crest factor** must rise
monotonically `attack-minus-9 < no-shaper ≈ shaper-default < attack-plus-9`, *after* the variants have
been loudness-matched to within 1.0 LU. Integrated loudness matched + crest factor moving is
**exactly** the claim "this changes punch, not volume", measured — and it is a claim a level change
cannot fake.

⛔ **Plant for the ffmpeg leg:** set `outputDb` on one variant to +3 instead of trimming it. Loudness
matching reddens (> 1.0 LU) while crest factor is unchanged — proving the two measurements are
independent and that the crest-factor leg is not just re-reading level.

### 7.6 What NO instrument in this tree can see — stated, not left for discovery

- **Whether "Transient Shaper" renders legibly in the mixer strip.** `InsertLabelBudgetTests` checks a
  budget, not pixels. Use `debug.captureUI`, and look.
- **B8 (the display-name `default:` arm).** No gate covers it; only a direct assertion on
  `ProjectStore`'s display name will. **Write that assertion.**
- **B7 (`MixerPresets.withFreshID`).** `effect-kind-surface.mjs` does not list that file as a surface,
  so a green gate run says nothing about it. L10's preset leg is the only instrument.
- **Whether it sounds like a transient shaper.** Only the §7.4 demo sets and a human.

---

## 8. Rejected alternatives, each with its reason

| # | alternative | why it loses |
|---:|---|---|
| **1** | **Reuse / port `TransientAnalyzer`** | §2. Allocates per flux frame (`:94`, `:257-263`), builds an FFT inside the call (`:157`), needs the global peak flux (`:83`) and a ±0.175 s two-sided median (`:88-95`), does file I/O (`:268-309`). It reads the future and allocates; both are disqualifying. Porting it is a rewrite, and the rewrite is a *different algorithm* — which is this document. |
| **2** | **Lookahead + peak-hold detector** (the Waves Smack Attack family) | Buys an exact cut of the first ~2 samples. Costs: a `maxLookaheadSamples × maxChannels` ring allocated at `prepare()`, a **new declared latency source** entering a guarantee measured sample-exact at m25-n, and `latencySamples ≠ 0` on an effect a user will put on every drum bus. **Two samples is not worth re-opening PDC.** If ever revisited it appends at slot 6+ and must declare its latency. |
| **3** | **RT-safe STFT / spectral-flux detector** (the `TransientAnalyzer` algorithm, made allocation-free) | A 1024-point FFT every 256 samples on the render thread, plus preallocated scratch, plus **inherent ~10.7 ms latency** (half a window) → PDC. ⚠️ **The disqualifier is LATENCY and whole-signal statistics, NOT raw CPU — I over-claimed this at first.** Counted honestly: a 1024-point real FFT is ~(N/2)·log2(N) butterflies per 256-sample hop ≈ **60–70 flops/sample**, plus windowing and magnitude, against ~30 flops + 3 transcendentals here — so roughly **2× this design, not the "three orders of magnitude" the first draft asserted.** It still loses, decisively, because it needs ~10.7 ms of lookahead and (as built, `TransientAnalyzer.swift:83-95`) a global peak and a two-sided median — for a **gain** decision that needs no spectral resolution at all. Spectral flux exists to find onsets *in time* in a file; a shaper only needs to know "is it rising faster than usual, right now". |
| **4** | **Linear differential (`envFast − envAttack`) instead of the dB ratio** | Level-dependent: the same hit 20 dB quieter produces 1/10 the differential and therefore 1/10 the shaping. The knob would mean something different at every fader position. **This is L6's plant**, so the rejection is enforced, not just argued. |
| **5** | **One-pole followers in the dB domain** | The step response's duration depends on the starting dB value, so the attack window would change with whatever preceded the hit (§3.3). Plausible-looking, subtly wrong, and invisible to any test that does not vary the pre-roll. |
| **6** | **A `detectMode` param (peak / RMS)** | Discrete → `Modulatable: refused` by rule 6.0.5, and it would be the *only* refused param in the table. Worse, RMS **smears the onset** — it averages away the exact event the detector exists to find. A transient detector that can be switched into a mode where it cannot detect transients is a trap, not a feature. |
| **7** | **A `stereoLink` param (or per-channel detection)** | Unlinked detection applies different gain per channel on every hit, which **moves the stereo image with the drummer**. Stereo-linked is the only correct default (`CompressorEffect.swift:261` — *"Stereo-linked peak detector"*), and an option to break it is an option to make the mix worse. |
| **8** | **`attackDb` / `sustainDb` as dimensionless −1…+1** (the SPL hardware's own knob) | No acceptance number is expressible. "Attack at +0.5" cannot be checked against anything, so §7.5 would have no measurable leg and the effect could ship inert the way `.modulation` did. The dB denomination **plus** the declared `fullShapeDifferentialDb = 12` normalisation is what makes "+6 dB raises the first 8.68 ms peak by 6.00 ± 0.5 dB" a falsifiable statement. |
| **9** | **Reserving slots for a future `lookahead` / `detectMode`** | Rule 6.0.1's corollary (`creative-effects.md:708-710`): appending is always safe, so a reserved slot buys an ordering that was never at risk and **puts a lie in `fx.describe`**. |
| **10** | **A `threshold` param** | A transient shaper is *not* a compressor: it responds to the **rate of change**, not to absolute level, which is exactly why it works at any fader position. A threshold would reintroduce the level dependence rejection 4 exists to prevent. The −70 dBFS detector floor (§3.4) is a noise gate, not a threshold, and it is fixed and declared for that reason. |
| **11** | **An internal limiter to catch the boosted peaks** | `creative-effects.md:859-862` already ruled this shape out for `.djFilter`'s resonance: *"Do not insert a limiter inside the effect — that makes [it] non-linear in a way an agent cannot predict and a user cannot undo."* Same verdict. `outputDb` + the honest note, and the user's own `.limiter` after it. |

---

## 9. The MCP surface — additive only

**`fxKindSchema` is SHARED by two tools.** Read at `mcp-server/src/server.ts:4283-4304` (the
`z.enum([...])`) and `:4305+` (the `.describe(...)` prose). Its consumers:

- `:4746` — `fx_add`: `kind: fxKindSchema.default("gain")`
- `:5704` — `fx_describe`: `kind: fxKindSchema.optional().describe("Effect kind to describe. …")`

**What to add:**

1. `"transientShaper"` appended to the enum **after `"phaser"` (`:4302`), before `"audioUnit"`
   (`:4303`)** — matching the Swift `Kind` order and keeping both lists diffable.
2. A paragraph in the shared `.describe(...)` prose naming the six params, the fact that `attackDb`
   is a **maximum** reached only at a full 12 dB differential, and the −70 dBFS detector floor.

⛔⛔ **THE PROSE IS SHARED, SO IT MUST NAME ITS TOOL.** `ROADMAP.md:4410-4414` records exactly this
trap: a claim written into `fxKindSchema` that was true of one tool and false of the other, plus — in
the same close — *"the whole `hallReverb` paragraph had been inserted INTO THE MIDDLE of the flanger's,
cutting it mid-sentence"*, with `effect-kind-surface.mjs` passing throughout **because presence is not
contiguity**. ⭐ **Therefore: append the new paragraph at the END of the existing prose, verify by
paragraph ORDER and a duplication count, and never by "is the word there".**

⛔ **Never rename or repurpose a live command or param.** The wire command count must stay at **227**
(§7.2 L13); this kind adds **zero** verbs — `fx.add` / `fx.setParam` / `fx.describe` are kind-generic
and address params **by name** (rule 6.0.11, `creative-effects.md:754-759`).

**Also required:** `mcp-server/README.md` (B15) and `claude-plugin/agents/sound-designer.md` (B16) are
**gated surfaces** — `effect-kind-surface.mjs:37-38, 46-47` will fail the build if the kind never
reaches them. And `claude-plugin/server/index.mjs` (B21) is the **generated bundle**; `/plugin update`
+ a stdio verification **with a negative control**.

---

## 10. Derived / echoed fields — and the distinction that has produced false documentation before

⛔⛔ **These are two different surfaces and they have been confused in this repo at least once, in
three places at once** (`ROADMAP.md:4410-4414`: *"a false wire claim in THREE places, where searching
by phrasing found ONE… `fx_describe` echoes `firstNotchHzAtSweepFloor` is false"*).

### 10.1 `Commands.effectParamsJSON` — a new arm at `Commands.swift:10690` (after `.phaser`)

Verified home: `Sources/DAWControl/Commands.swift:10450`. It appears in:

- the `params` object of **`fx.add` results**
- the `params` object of **`fx.setParam` results**
- **`project.snapshot`** (via `effectsJSON`, called at `:10430`)

It carries the six params **plus** derived keys, following the `phaser` precedent at `:10704-10716`
(*"DERIVED, through `PhaserParams`, the one home, never re-derived here"*):

| key | value | kind |
|---|---|---|
| `attackWindowMs` | `TransientShaperParams.attackWindowMs(attackMs:)` → `0.2893 × attackMs` | **per-instance, derived** |
| `fullShapeDifferentialDb` | `TransientShaperParams.fullShapeDifferentialDb` = 12.0 | **constant** — echoed so an agent knows what `attackDb: +6` actually promises without reading source |
| `detectorFloorDb` | `TransientShaperParams.detectorFloorDb` = −70.0 | **constant** — echoed so "why did nothing happen on my quiet stem" is answerable from the wire |

⛔ **Derive through the DAWCore statics. Never re-derive the arithmetic in `Commands.swift`** — that
is how the record and the source come to disagree while both look right.

### 10.2 `fx.describe` — a **separate case**, and it needs **NO code change**

Verified at `Sources/DAWControl/Commands.swift:2733-2780`. It is built entirely from
`EffectDescriptor.Kind.allCases` (`:2754`, `:2759`) and `EffectParamSpec.specs(for:)` (`:2765`), and
each param object carries exactly: `name`, `min`, `max`, `default`, `unit`, `curve`, and `note` when
non-nil (`:2766-2775`).

⛔ **Therefore, stated flatly so it is not mis-documented a second time:**

- `fx.describe` **does NOT** echo `attackWindowMs`, `fullShapeDifferentialDb` or `detectorFloorDb`.
- `fx.describe` **does NOT** echo `modulatable` **for any kind** (read `:2766-2773` — the field is
  absent). That gap is already filed as `m39-f-3` and is **not** this item's to fix.
- `fx.describe` and `fx.add`'s kind parsing (`parseEffectKind`, `:9684-9693`) are both
  `rawValue`/`allCases`-driven and require **no new arm**. ⚠️ **This corrects
  `creative-effects.md:1441`**, whose §11.0 table says `Commands.swift` changes for *"`fx.add` kind
  parsing and `fx.describe`"*. Measured: neither does. The **only** compiler-forced change in
  `Commands.swift` is `effectParamsJSON` (A10).
- Anything an agent needs to **know before calling** goes in the spec's `note:` (surfaced verbatim by
  `fx.describe`). Anything reporting **this instance's current state** goes in `effectParamsJSON`.

---

## 11. Risks

| # | risk | mitigation |
|---:|---|---|
| **R1** | An attack boost raises **true peak** and can clip a downstream stage | `outputDb` (slot 4) + a LEVEL WARNING in `attackDb`'s `note`, in the style of `phaser.feedback`'s at `Effects.swift:3944-3969` (*"LEVEL WARNING, because it is real and not a mixing choice: moving this CHANGES THE LOUDNESS, in either direction, and how much depends on the material"*, read at `:3955-3958`). ⛔ **No internal limiter** — rejected alternative 11 |
| **R2** | **§9.3 loudness confound** — a listener picks the loudest variant and calls it the best | §7.4: `outputDb`-trim every variant to within 1.0 LU, and report **crest factor** as the axis. The shaping survives loudness matching by construction |
| **R3** | **The demo is built on a pad and proves nothing while exiting 0** | §7.4's material ruling, frozen, and the §9.4 listening note tells the listener what would make it inaudible (the `audibility-and-novice` user rule) |
| **R4** | **B7 and B8 are compiler-silent and no gate covers them** | Named in §6.B with their exact lines, given their own legs in L10, and flagged in §7.6 as invisible to `effect-kind-surface.mjs` |
| **R5** | **The generated plugin bundle goes stale** — one went 18 days stale in this tree, and the installed copy is already missing five kinds | `/plugin update`, then **stdio-verify with a negative control** before announcing. Do not hand-edit `claude-plugin/server/index.mjs` |
| **R6** | `attackDb < 0` leaves a ~0.05 ms unattenuated leading edge | Accepted and documented (§3.7). It is what zero latency costs, and the alternative is R7 |
| **R7** | A future implementer adds lookahead "to fix R6" and does not declare it | §3.7 carries the explicit ⛔. L9's chain-latency assertion is the instrument that catches it |
| **R8** | **"Transient Shaper" is the longest built-in name yet** (15 chars) and may overflow the insert slot | `InsertLabelBudgetTests` (§6.D) **plus** an actual look via `debug.captureUI` — §7.6. ⚠️ A budget test passing is not a legible label |
| **R9** | `ARCHITECTURE.md`'s wire-totals ledger is **already four closes stale** (`creative-effects.md:1453`) and this item touches that file | B18: fix the ledger while there, or the drift compounds again. ⛔ Not fixed by this document |
| **R10** | Concurrent agents in the same tree overwrite each other's scratch files and one `.build` | Namespace every temp file (`m39ts-*` for this design's own work) and **run one DSP agent at a time** — `MEMORY.md`, 2026-09-20 |

---

## 12. Implementation order — the legs, with gates between them

| leg | work | gate before the next leg starts |
|---|---|---|
| **1** | `TransientShaperParams` + the §3.5 statics + the spec table (A1–A6, A7) | L1, L2 green. ⚠️ **Find and run the allocation-probe pattern first** (`PhaserTests.swift:1053-1063`) so leg 3 has an instrument on day one |
| **2** | `TransientShaperEffect.swift` — detector + gain law + smoothing (A8) | L3, L4, L5, L6, L7, L8, L9 green, **each with its plant run and the redness recorded** |
| **3** | Persistence + presets: the **eight** hand sites (B1–B8) | L10 green with **all eight** plants, positive-controlled against `phaser` |
| **4** | Store / control / editor / mixer surfaces (A9–A13, B9–B12) | L11, L12, L13 green; `GATE_SELFTEST_EXTRA_KIND` proves L12 can fail |
| **5** | MCP + docs surfaces (B13–B18, B20) | `effect-kind-surface.mjs` green; prose verified by **paragraph order + duplication count**, not by presence |
| **6** | Demo sets + the byte gate (§7.3, §7.4) | `m39y-transient-shaper-bytes.mjs` exit 0, **both plants shown to redden it** |
| **7** | `/plugin update` (B21) + tick the roadmap (B19) | stdio verification with a negative control |

⛔ **Do not collapse legs 2 and 3.** If the byte gate reddens across a combined change you will not
know whether the DSP or the persistence did it — `creative-effects.md:1157-1158`'s explicit warning
about the chorus migration, which this tree already paid for once.

---

## 13. Flagged: what needs full Xcode, and what needs the user's word

- **Nothing in this design requires full Xcode.** No entitlements, no AUv3, no signing, no code-signing
  identity. It is a built-in effect in `DAWEngine`, built by `swift build` and tested by
  `./scripts/test.sh`. (Xcode 26.6 *is* installed on this machine, but this item does not need it.)
- **Commits require the user's explicit word.** None has been given.
- **The item id (`m39-y` vs `m39-p`) is the orchestrator's call** — `docs/ROADMAP.md` is their file
  (§0.2).
- **`docs/ARCHITECTURE.md` "Key future decisions"** should record the two settled rulings below. ⛔ This
  document does **not** edit that file — the constraint on this run is that the design doc is the only
  file written — so it is on the implementer's checklist as B18:
  1. **Transient detection on the render path is a differential envelope follower in the linear domain
     with dB-ratio differentials, zero lookahead, `latencySamples == 0`.** `TransientAnalyzer` is
     offline-only and is never reachable from the render path.
  2. **`EffectDescriptor` has EIGHT hand-written per-kind rebuild/persistence sites, not six** — the
     six in `ProjectDocument.swift` plus `MixerPresets.withFreshID()` and `ProjectStore`'s
     display-name `default:` arm. The cause is that `EffectDescriptor.init`'s params are all
     `= nil`-defaulted (`Effects.swift:236-237`), so every field-by-field rebuild call site is
     compiler-silent.

---

## 14. Summary of unverified claims

Honest gaps, so nobody quotes them as measured:

- **UNVERIFIED:** the wall-clock cost of the detector. §3.6 gives an exact **operation count** and a
  shipping comparison (`CompressorEffect` runs 2 transcendentals/frame; this runs 3). No nanosecond
  figure is asserted. **First implementation leg should measure one.**
- **UNVERIFIED:** that "Transient Shaper" fits the insert-slot label budget (R8). The budget test
  exists; I did not run it, and per the constraints on this run I could not.
- **UNVERIFIED:** the exact current contents of `mcp-server/README.md`'s and
  `claude-plugin/agents/sound-designer.md`'s kind lists. I confirmed both are **gated surfaces**
  (`effect-kind-surface.mjs:37-38, 46-47`) and that `phaser` reaches both (they appear in the 33-file
  census), but I did not read the lists themselves.
- **UNVERIFIED:** whether `docs/ARCHITECTURE.md`'s wire ledger is *still* 204/209. I am repeating
  `creative-effects.md:1453`'s measurement, which is itself dated 2026-09-19 — ⚠️ and in this tree
  **a staleness warning rots too**. Re-measure before acting on it.
- **All other file:line citations in this document were read directly.** Every grep that returned
  nothing was positive-controlled against something known to exist (§0.1, §0.2, §6).
