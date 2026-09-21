# Dynamic EQ — design spike (adopts `m23-cl`)

**Date:** 2026-09-20
**Item:** `m23-cl` (`docs/ROADMAP.md:1113`) — **ADOPTED, not re-filed.** The ADOPT banner at
`docs/ROADMAP.md:3749` names `m23-cl` explicitly and cites `m27-n` duplicating `m26-a` as the
merge that precedent cost. The M39 ranked set (`docs/ROADMAP.md:4675`) asks for the **dynamic EQ
half only**; the multiband-compressor half of `m23-cl` stays open and its checkbox must NOT be
ticked by this work.
**Route:** `daw-architect` (this spike) → `audio-dsp-engineer` (build).
**Status:** design only. Zero implementation was written.

---

## RECOMMENDATION

Ship the dynamic EQ as a **NEW effect kind `.dynamicEQ`**, not as a mode on the shipped `.eq`:
**four identical bell bands in series**, each one a single side-path biquad with the identity
`y = x + (G − 1)·BP(x)`, where `BP` is the existing constant-0-dB-peak band-pass
(`EQFilterResponse.bandPassSection`, `Sources/DAWCore/EQFilterResponse.swift:155`) and `G` is a
detector-driven linear gain. **There is no crossover and there is no band-splitting — the prior in
the brief is CONFIRMED.** The same one filter per band serves BOTH the detector and the gain
application, so the detector is band-isolated for free; the filter's coefficients depend only on
`(freq, Q, sampleRate)` and are therefore **invariant under gain change**, which is the whole
reason this topology is cheap: moving the band's gain per sample costs **one multiply and one
add**, zero trig, zero coefficient recomputation, zero lookahead, and **`latencySamples` is a
literal `0`**. Eight parameters per band × 4 bands = **32 automation slots**, laid out band-major
so slot = `(band−1)·8 + p`. The build cost is the tree's routine new-kind blast radius — **9
`case .<kind>` sites (8 compiler-forced + 1 with a `default:` arm) across ~18 files**, measured —
plus one new render file; **no new wire command and no new MCP tool** (`fx.add` parses
`EffectDescriptor.Kind(rawValue:)` at `Sources/DAWControl/Commands.swift:2753`), so the 227-command
/ 232-tool pins do not move.

---

## 0. WHAT I MEASURED vs WHAT I ASSUMED

Read this section first. Everything below leans on it.

### MEASURED — I opened the file and read the line

| Claim | Evidence |
|---|---|
| `.eq` is a FIXED 6-logical-band / 8-biquad-slot series cascade (HP pair, low shelf, peak1, peak2, high shelf, LP pair) — not an N-band array | `Sources/DAWCore/EQFilterResponse.swift:39-45`; `Sources/DAWEngine/Effects/EQEffect.swift:11-16,37` |
| `.eq` has exactly **22** params; slots 0-9 are the original band-grouped ten, slots 10-21 are the m22-a appends and are **not** band-grouped | `Sources/DAWCore/Effects.swift:3655-3724`; the slot roll-call is restated in `Sources/DAWEngine/Effects/EQEffect.swift:153-163` |
| `.eq`'s render loop nesting is **channel-outer → band → frame** | `Sources/DAWEngine/Effects/EQEffect.swift:205-235` |
| `EQEffect.latencySamples` is a literal `0` | `Sources/DAWEngine/Effects/EQEffect.swift:123` |
| `.eq` is bit-exact transparent when every band is neutral, and an inactive band's state is not even advanced | `Sources/DAWEngine/Effects/EQEffect.swift:24-30`, `:213` (`where bandActive[band]`); the skip law itself at `Sources/DAWCore/EQFilterResponse.swift:216-217` |
| `bandPassSection` is the **constant-0-dB-PEAK** form, chosen so a threshold means the same dBFS banded as broadband, and it currently has exactly ONE caller | `Sources/DAWCore/EQFilterResponse.swift:131-169` (rationale at `:134-142`, the "not part of the EQ's 8-slot plan" note at `:150-154`) |
| `CompressorEffect` hangs the de-ess filter on the DETECTOR only, keeps the branch outside the arithmetic, and reports a literal `0` latency | `Sources/DAWEngine/Effects/CompressorEffect.swift:13-34`, `:194-200`, `:399-405` |
| The compressor's detector = instant-attack peak follower with a **fixed 5 ms** decay, denormal-flushed | `Sources/DAWEngine/Effects/CompressorEffect.swift:182`, `:471-472` |
| The compressor's gain computer is a quadratic soft knee in the log domain; its smoother picks attack when `targetDb < env`; it snaps one-sidedly at `env > -1e-10` | `Sources/DAWEngine/Effects/CompressorEffect.swift:474-484`, `:487`, `:489` |
| The compressor caches detector coefficients and skips trig unless `(mode, freq, q, sampleRate)` moved, seeded with NaN so the first derive always runs | `Sources/DAWEngine/Effects/CompressorEffect.swift:102-107`, `:287-292` |
| The compressor CLEARS its filter sections when the mode LEAVES, never when it arrives | `Sources/DAWEngine/Effects/CompressorEffect.swift:270-280` |
| The NaN guard lives at the caller, not in `Biquad`, because a branch would have changed the ring modulator's arithmetic | `Sources/DAWEngine/Effects/Primitives/Biquad.swift:37-44`; the guard itself at `Sources/DAWEngine/Effects/CompressorEffect.swift:442-456` |
| `InlineBiquads` is a fixed-size stack bank of **8** sections, indexed in its one existing caller by CHANNEL | `Sources/DAWEngine/Effects/Primitives/Biquad.swift:83-114`; used by channel at `CompressorEffect.swift:413-420`, `:438-441` |
| ⭐ **A persisted automation lane stores the param NAME, never an index** | `Sources/DAWCore/Automation.swift:81-84` (decode), `:104-107` (resolve) |
| ⭐ **The slot INDEX is derived at snapshot-build time from `specs(for:)` and lives only in DAWEngine** | `Sources/DAWEngine/Automation/AutomationSchedule.swift:371-379`; the Int32 field at `:24`; the modulation twin at `Sources/DAWEngine/Modulation/ModulationSnapshotBuilder.swift:129`, `:240` |
| ⭐ A persisted modulation route also carries an `AutomationTarget`, i.e. a NAME | `Sources/DAWCore/Modulation.swift:375-407` |
| Effect-param automation lanes are capped at **64 per strip** and the excess is SILENTLY DROPPED by a `.prefix` | `Sources/DAWEngine/Automation/AutomationSchedule.swift:57-60`, `:91`; the modulation twin at `Sources/DAWCore/Modulation.swift:434-438` |
| Automation refuses `delay.sync`/`delay.division` and `saturator.oversampling`; the saturator refusal is about PARAM-DEPENDENT LATENCY and the identical `.clipper` param is deliberately NOT refused | `Sources/DAWCore/Automation.swift:108-132` |
| A new kind touches **9** `case .<kind>` arms; **8** are compiler-forced, **1** sits above a `default:` | see §8 for the full list; the `default:` is `Sources/DAWCore/ProjectStore.swift:3280` |
| The mixer "+" menu list is HAND-MAINTAINED and its own comment says the compiler cannot catch an omission | `Sources/DAWApp/Mixer/MixerStripView.swift:8-14` |
| The `masterChainBuiltInOnly` error text hand-lists every built-in kind and is CONTRACT wording, gate-checked | `Sources/DAWCore/MediaImporting.swift:601-604` |
| The sidechain kind whitelist is `compressor || gate` | `Sources/DAWCore/ProjectStore.swift:3446` |
| `fx.add` / master-chain add parse the kind generically through `EffectDescriptor.Kind(rawValue:)` | `Sources/DAWControl/Commands.swift:2753`, `:9688` |
| Per-kind param counts today: `.eq` 22, `.hallReverb` 14, `.compressor` 10, everything else ≤ 8 | counted off `Sources/DAWCore/Effects.swift:3614-5395` |
| Compressor ranges I mirror: threshold −60…0, ratio 1…20, attack 0.1…200, release 5…2000 | `Sources/DAWCore/Effects.swift:678-681` |
| EQ ranges I mirror: peak freq 20…20 000, gain −24…+24, Q 0.1…18 | `Sources/DAWCore/Effects.swift:455-458` |
| `CompressorParams.detectorMode` is `.refused` for modulation (discrete); the two continuous de-ess params are `.warned` | `Sources/DAWCore/Effects.swift:3759-3800` |
| `InsertLabelBudgetTests` sweeps `Kind.allCases` and fails on any new name that does not fit 85 pt on a channel strip | `Tests/DAWAppKitTests/InsertLabelBudgetTests.swift:14-20`, `:41-56` |
| MCP carries hand-maintained kind enumerations in at least 3 places | `mcp-server/src/server.ts:4297-4305`, `:4894`, `:10488-10489` |

### MEASURED — numerically, by me, in a scratchpad script today

The side-path identity and its consequences were **computed, not recalled**. Numbers reproduce
from the formulas in §3; the script is scratch and deliberately not committed.

| Measurement | Result |
|---|---|
| `bandPassSection` peak gain at `freq` | **4.63e-14 dB**, i.e. exactly 0 dB to double precision, at Q = 2 |
| `\|1 + (G−1)·BP(f_c)\|` for requested gains −12, −6, 0, +6, +12 dB | **−12.00000, −6.00000, +0.00000, +6.00000, +12.00000 dB** — exact, with ONE unchanged coefficient set |
| Wrong-side excursion of the side-path bell (response on the boost side of 0 dB while cutting, or vice-versa), swept 20 Hz…20 kHz at ±6/±12/−18 dB | **+0.0000 dB — none, at any gain.** The bell is monotone and clean in both directions |
| Half-gain bandwidth at f_c = 1 kHz, Q = 2: **RBJ peaking** (`EQFilterResponse.gainBand` kind 1) | **499.3 Hz at +3, +6, +12 AND +18 dB** — constant, by construction |
| Half-gain bandwidth, same f_c/Q: **side-path bell** | **592.5 / 705.1 / 994.4 / 1402.2 Hz** at +3 / +6 / +12 / +18 dB — it WIDENS with gain |
| Side-path **shelf** built from a 2nd-order Butterworth low-pass (`1 + (G−1)·LP`), −9 dB at a 200 Hz corner | ⛔ **+0.82 dB AT THE CORNER — a boost where a cut was asked for.** This construction is REJECTED |
| Side-path shelf built from a **first-order** LP/HP (equivalently a 1st-order allpass, Zölzer form), ±6/±12 dB | Clean: **+0.0000 dB wrong-side excursion**, correct plateau — but boost and cut are NOT mirror-symmetric at the corner (+3.963 dB vs −2.037 dB for a ±6 dB shelf) |

### ASSUMED — stated as assumption, flagged for the builder to settle

1. **"Dynamic EQ" fits the 85 pt channel-strip label budget.** I did not run the measurement.
   `InsertLabelBudgetTests` sweeps `allCases` and will fail loudly the moment the kind is added, so
   this assumption **self-verifies at build time**; it does not need a separate check, only a
   willingness to rename if it fails. ("Bass Enhancer" already passes and is longer.)
2. **Per-sample CPU cost.** My estimate is ~4× `CompressorEffect`'s transcendental load (2 per
   sample per band × 4 bands, vs the compressor's 2), i.e. roughly 1–2 % of one core per instance
   at 48 kHz. **This is arithmetic on an unmeasured base, which is precisely the error
   `docs/research/2026-09-19-plugin-program-inventory.md` §11 records against itself.** A benchmark
   is an acceptance gate (§10 G7), not an afterthought.
3. **A 4-band × 8-param editor card fits the insert editor.** `EffectEditorModel.groupTable`
   (`Sources/DAWAppKit/EffectEditorModel.swift:150`) already renders `.eq` as 6 groups of 3-4; 4
   groups of 8 is a different shape and I have not looked at a pixel. §10 G8 makes this a gate with
   a named fallback (3 bands) rather than a hope.
4. **Whether `MixerPresets.swift` should gain a dynamic-EQ starting point.** That file is a
   measured touch site (`Sources/DAWCore/MixerPresets.swift:73`) but I read only its
   `EffectDescriptor` construction, not its preset semantics. Builder decides there, on sight.

### A CORRECTION I OWE THE TREE

`docs/research/2026-09-19-plugin-program-inventory.md` §7 cites the sidechain kind whitelist at
`Sources/DAWCore/ProjectStore.swift:3414`. **Measured today, it is at `:3446`.** The quoted code is
correct; the line number has rotted by 32 lines. Nothing downstream of that research doc depends on
the number, but a spot-check would have produced a confusing miss.

---

## 1. Q1 — CROSSOVER OR NO CROSSOVER

### The prior is CONFIRMED. A dynamic EQ has no crossover, and the reason is structural, not stylistic.

A **multiband compressor** splits `x` into N disjoint bands, compresses each independently, and
sums them back. The sum is the problem: the band filters must be *complementary* — their outputs
must reconstruct `x` when every band sits at unity — or the unit colours the signal even when it is
doing nothing. That reconstruction constraint is what makes Linkwitz-Riley vs. Butterworth vs.
linear-phase a load-bearing decision, and it is what earned `m23-cl` its **L** weight. It also
drags in phase behaviour at every crossover point and, for the linear-phase option, latency.

A **dynamic EQ** does none of that. Its structure is

```
y = H_1(H_2(H_3(H_4(x))))      each H_b a single peaking section whose gain is level-driven
```

Every section is a **full-band** filter that is unity everywhere except near its own centre. There
is no disjoint decomposition, so there is nothing to reconstruct, so **there is no complementarity
constraint and therefore no crossover topology to settle.** When a band's gain is exactly 0 dB its
section is exactly `H(z) = 1` — algebraically, not approximately — and the neutrality is free.

The recommended implementation makes that even more explicit. Write the peaking section in its
**side-path (Regalia–Mitra) form**:

```
H_b(z) = 1 + (G_b − 1) · BP_b(z)          BP_b = constant-0-dB-peak band-pass at (f_b, Q_b)
```

The algebra, for the record, using RBJ's α = sin(ω₀)/(2Q) and D(z) = (1+α) − 2cos(ω₀)z⁻¹ + (1−α)z⁻²:

```
1 + (G−1)·α(1 − z⁻²)/D(z)  =  [(1 + Gα) − 2cos(ω₀)z⁻¹ + (1 − Gα)z⁻²] / D(z)
```

The **denominator does not contain G**. The poles are fixed by `(f, Q, fs)` alone. That is the
property that carries the whole design: the gain can move at audio rate without recomputing a
single coefficient, and the filter's memory never sees a discontinuity.

Contrast with RBJ's peaking form as shipped (`Sources/DAWCore/EQFilterResponse.swift:70-77`), whose
denominator is `1 ± α/A`: **its poles move with gain.** Making an RBJ band dynamic means
recomputing coefficients every time the detector moves, which forces a control stride, which forces
a stride-rate decision, which is a second shape decision this design does not have to make.

**Nothing forces a crossover. The crossover decision stays entirely with the multiband-compressor
half of `m23-cl` and must be made when that half is picked up.** The spike therefore concludes that
the dynamic EQ is a **small-to-medium** item, not an **L** one.

### What the sum-vs-series choice costs, since it is the nearest thing to a topology decision here

Bands may be summed in **parallel** (`y = x + Σ_b (G_b − 1)·BP_b(x)`, every detector sees the same
clean input) or cascaded in **series** (`x_{b+1} = x_b + (G_b − 1)·BP_b(x_b)`).

**SERIES is recommended.** Reasons, in order of weight:

1. It is what `.eq` already is (`Sources/DAWEngine/Effects/EQEffect.swift:213` walks the bands in
   series over one buffer). Two EQ-shaped kinds whose curves compose by different rules is a trap
   for a user who reasonably expects "two +6 dB bells at 1 kHz" to mean the same thing in both.
2. Parallel summation of two overlapping bands does not give the product of their responses; it
   gives `1 + (G₁−1)BP₁ + (G₂−1)BP₂`, which overshoots where they overlap. Series gives the product,
   i.e. dB-additive, which is what an EQ curve display and every user's intuition assume.
3. Cost is identical.

The accepted consequence: band *b*'s detector sees bands 1…*b*−1's output. That is standard and
arguably right — band 3 should react to what band 2 has already done to the signal. **It must be
documented in the kind's header, because it is the kind of thing that looks like a bug from the
outside.**

---

## 2. Q2 — NEW KIND, NOT A MODE ON `.eq`

### Recommendation: **a new kind, `.dynamicEQ`.** The decisive argument is loop nesting, not slots.

Both options were priced. Here is the honest comparison.

### Option A — a MODE on the shipped `.eq` (the `m39-ae` shape)

**What it would buy.** Zero new switch sites. Zero new files in the kind registry. No display-name
arm, no picker entry, no MCP enum edits, no `masterChainBuiltInOnly` contract-text change. This is
genuinely the cheap option and `m39-ae` proved it works — the de-esser shipped last night by
appending three slots (7/8/9) to `.compressor` and touching **none** of the eight per-kind sites.

**What kills it.** Three things, any one of which is sufficient.

1. ⛔⛔ **The render loop must be re-nested, and `.eq`'s current nesting is the thing the null pin
   protects.** A dynamic band needs a **stereo-linked** detector — one gain for all channels, or
   the stereo image shifts every time the band moves. Stereo linking requires `frame` to be OUTSIDE
   `channel`. `EQEffect.process` is **channel-outer → band → frame**
   (`Sources/DAWEngine/Effects/EQEffect.swift:205-235`): channel 0's entire block is filtered before
   channel 1 exists. There is no way to link a per-sample detector across channels in that nesting.
   So Option A means `.eq` grows a **second, complete render implementation** with the opposite
   nesting — and the shipped inner loop (`:220-226`) is exactly the arithmetic that
   `eqNeutralSettingsAreTransparent` and the m22-a EQv2 null pin exist to freeze. The
   branch-outside-the-arithmetic rule can be honoured (the old limb stays character-for-character),
   but the surface being duplicated is the highest-risk five lines in the effects tree, and a
   project that turns on one dynamic band would render its **static** bands through the other
   nesting — different accumulation order, different low bits — for no benefit.
2. ⛔ **Two incompatible peaking topologies inside one kind.** `.eq`'s bands are RBJ with
   gain-dependent poles; a dynamic band must have gain-independent poles (§1). The **same band at
   the same `peak1Freq`/`peak1Q`/`peak1GainDb` would have a measurably different skirt** depending
   on whether its dynamics were switched on — 499.3 Hz vs 705.1 Hz of half-gain bandwidth at +6 dB,
   measured. A kind whose static control changes meaning when a different control is enabled is not
   a mode, it is two kinds sharing a name.
3. ⚠️ **`.eq` has only four gain bands and they are shape-fixed** (2 shelves + 2 peaks,
   `EQFilterResponse.swift:39-45`). A dynamic EQ wants freely-placed bells. Option A would either
   inherit the shelf/bell split or grow a `shape` param per band, which is a further 4 slots on a
   kind that is already the largest in the tree at 22.

**And the bit-exactness bill.** Option A inherits the full two-guard obligation on a **shipped**
kind used by every existing project, over a five-line loop, forever. Option B inherits none of it,
because no project contains a `.dynamicEQ` yet.

### Option B — a new kind `.dynamicEQ` (RECOMMENDED)

**What it costs, measured (§8).** 9 `case` arms across 7 files, ~9 more non-switch touch points,
one new render file, ~3 MCP enum edits, one contract-text string. This is the *routine* cost of
this tree: M39 has paid it **ten times** in this milestone (11 kinds → 21). It is understood,
mechanical, and mostly compiler-enforced.

**What it buys.** A fresh slot table starting at 0. Free choice of topology. Uniform bands. No
obligation over shipped audio. No risk to the `.eq` null pin, which stays untouched.

### The one cost of Option B that must be written down, not waved at

**`.eq` and `.dynamicEQ` will both have `freq`/`Q` controls that do not mean the same thing.** That
is a real user-facing wart and it is the price of getting gain-invariant poles. Mitigation is
mandatory, not optional:

- every `bandNQ` spec carries a `note:` saying so, in the `fx.describe` teaching voice, naming the
  measured numbers ("at Q 2 a ±6 dB band here is about 700 Hz wide at half gain where the EQ's
  would be 500 Hz, and it widens further as the band moves harder");
- the kind's header comment states the reason (gain-invariant poles) so the next reader does not
  "fix" it into RBJ;
- `EffectHonestyNote` (`Sources/DAWAppKit/EffectHonestyNote.swift:83-103`) is the existing home for
  "this kind's name over-promises" verdicts. This is not that — the name is honest. **Recommendation:
  land `.dynamicEQ` in the no-note list alongside `.eq`, and carry the Q caveat in the param note
  where a user actually reads it.**

---

## 3. ⭐ Q3 — THE AUTOMATION-SLOT BUDGET

### The brief's premise is MEASURABLY WRONG, and the correction matters. It does not, however, change the design.

> The brief: *"the INDEX of a spec in `EffectParamSpec.specs(for:)` **IS** the automation slot, and
> it is append-only forever — saved user automation lanes reference positions."*

The first half is true at render time. **The second half is false on disk.**

- A persisted automation lane's target is `.effectParam(effectID: UUID, paramName: String)`. The
  decoder reads a **string**: `Sources/DAWCore/Automation.swift:81-84`. Range resolution looks the
  name up in `specs(for:)`: `:104-107`, `:134-135`.
- The **index** first appears in `DAWEngine`, derived at schedule-build time:
  `AutomationSchedule.resolveEffectParamLanes` does
  `EffectParamSpec.specs(for: effect.kind).firstIndex(where: { $0.name == paramName })`
  (`Sources/DAWEngine/Automation/AutomationSchedule.swift:371-379`) and hands the result to
  `EffectParamLaneSpec.paramSlot`.
- The modulation layer does the identical thing (`ModulationSnapshotBuilder.swift:129`, `:240`), and
  its persisted `ModulationRoute` carries the same name-keyed `AutomationTarget`
  (`Sources/DAWCore/Modulation.swift:375-407`).
- I searched for a persisted `Int` slot and found none: every `paramSlot` occurrence lives under
  `Sources/DAWEngine/`.

**So reordering `specs(for:)` would not silently re-point a saved lane.** What it WOULD do is
desynchronise `specs(for:)` from the effect's own `storeAutomatedParam(slot:)` switch and its
`guard (0...N).contains(slot)` — and those two live in different modules and are edited by
different agents. `EQEffect.swift:164-193` is 22 hand-written arms that must agree, positionally,
with `Effects.swift:3655-3724`. **That coupling is the real hazard, and it is worse than a
persistence hazard in one specific way: the guard.** A lane on a slot the guard rejects is
`return`-ed silently — an **inert lane**, exactly the failure `Automation.swift:108-132` describes
for `delay.sync`. Nothing logs. Nothing fails. The user's automation simply does nothing.

### Therefore: obey append-only anyway. Three reasons, none of them the one in the brief.

1. The `specs` table and the `storeAutomatedParam` switch are compiled together but are not
   checked against each other by any compiler rule. The only thing keeping them aligned is the
   discipline and the dozens of `// APPENDED so the slot indices never move` comments, which are
   load-bearing documentation even though the persistence claim behind them is stronger than the
   truth.
2. `AutomationRenderer` / `ModulationEvaluator` hold **live cursors** keyed by `(effectID,
   paramSlot)` (`AutomationSchedule.swift:24`, `ModulationEvaluator.swift:130-138`). A reorder
   between snapshot builds within one session is a real in-flight hazard even though a reload is
   not.
3. It costs nothing. There is no upside to reordering.

### What this means for the design: **the slot budget does NOT dominate.**

A new kind's table starts at index 0 with no history, so append-only constrains nothing at design
time — it only constrains v2. The constraints that ARE real for a 32-param kind are three, and all
three are soft:

| Real constraint | Measured | Consequence |
|---|---|---|
| Effect-param automation lanes **+ modulated effect params**, per strip | ⛔ **64, ONE SHARED BUDGET** — `Sources/DAWCore/Modulation.swift:434-438` says it outright: *"The two caps SHARE ONE BUDGET: a modulated-but-unautomated effect param costs a synthetic lane, so `lanes + modulatedEffectParams <= 64` on a strip."* Excess is dropped by a bare `.prefix` (`AutomationSchedule.swift:57-60`, `:91`) | ⚠️⚠️ **ONE fully-automated `.dynamicEQ` consumes HALF a strip's entire automation-plus-modulation budget.** Automate all 32 slots and modulate 32 more params anywhere on that strip and lanes start vanishing silently. **This is the single real cost of a 32-param kind** and it belongs in the `fx.describe` note |
| Largest existing kind | `.eq` at 22, `.hallReverb` at 14 | 32 would be the largest by 45 %. That is a UI and agent-comprehension cost (§10 G8), not a correctness one |

**The finding, stated plainly:** the slot budget is not what forces this design. **Loop nesting and
pole-invariance are.** The budget is roomy; the brief's fear was well-placed but lands on the wrong
constraint.

---

## 4. The design in full

### 4.1 Band layout — 4 identical BELLS, no shelves in v1

Four bands, all the same shape, param blocks identical. Defaults spread across the spectrum
(120 / 500 / 3000 / 8000 Hz) so the four cards read left-to-right like an EQ.

**Why no shelves, when they are the most-wanted dynamic move (a dynamic high shelf is a
de-harsher):** because the measurement said no, twice.

- A shelf built the obvious way — `1 + (G−1)·LP` with a 2nd-order Butterworth low-pass — **boosts
  by +0.82 dB at the corner while cutting 9 dB.** Measured. That is a defect, not a character.
- A shelf built from a first-order section IS clean (measured: zero wrong-side excursion) but is
  6 dB/oct only, has **no Q**, and is not boost/cut symmetric at the corner (+3.963 vs −2.037 dB for
  ±6 dB). A shelf band would therefore need a different param block from a bell band — breaking the
  uniform `slot = (band−1)·8 + p` arithmetic that makes 32 slots reviewable — or would carry a dead
  `Q`.

**A wide bell (Q ≈ 0.5-0.7) at 8 kHz is a serviceable stand-in for a dynamic high shelf**, and
shelves stay available as a clean future append: a per-band `shape` param (4 slots appended at 32-35)
plus a first-order side-path helper in `EQFilterResponse`. Filed, costed, not built.

**The payoff of bells-only is large and worth stating:** `bandPassSection`
(`Sources/DAWCore/EQFilterResponse.swift:155`) is the **only** side-path filter the kind needs.
**DAWCore gains zero new coefficient math.** The dynamic EQ becomes `bandPassSection`'s second
caller, exactly as the brief predicted, and `Biquad`/`InlineBiquads` their third.

### 4.2 The 32 slots

Band-major, 8 per band, `slot = (band−1)·8 + p`. Names `band1Mode` … `band4ReleaseMs`.

| p | name | range | default | unit | curve | modulatable |
|---|---|---|---|---|---|---|
| 0 | `bandNMode` | 0…2 | **0 (off)** | linear | `.linear` | `.refused` (discrete — the `detectorMode` precedent, `Effects.swift:3759`) |
| 1 | `bandNFreq` | 20…20 000 (`EQParams.peakFreqRange`) | 120 / 500 / 3000 / 8000 | Hz | `.logarithmic` | `.warned` (zippers — every `.eq` freq is `.warned`) |
| 2 | `bandNQ` | 0.1…18 (`EQParams.qRange`) | 2 | linear | `.linear` | `.warned` |
| 3 | `bandNThresholdDb` | −60…0 (`CompressorParams.thresholdRange`) | −18 | dB | `.linear` | `.yes` |
| 4 | `bandNRatio` | 1…20 (`CompressorParams.ratioRange`) | 4 | ratio | `.linear` | `.yes` |
| 5 | `bandNRangeDb` | −24…+24 (`EQParams.gainDbRange`) | **−6** | dB | `.linear` | `.yes` |
| 6 | `bandNAttackMs` | 0.1…200 (`CompressorParams.attackRange`) | 10 | ms | `.linear` | `.yes` |
| 7 | `bandNReleaseMs` | 5…2000 (`CompressorParams.releaseRange`) | 100 | ms | `.linear` | `.yes` |

Every range is **mirrored from an existing constant**, never re-spelled. Reuse the existing
`static let`s directly where the semantics match (`EQParams.peakFreqRange`, `EQParams.qRange`,
`EQParams.gainDbRange`, `CompressorParams.thresholdRange` / `.ratioRange` / `.attackRange` /
`.releaseRange`) — a second spelling of the same range is how two controls in one tree come to
disagree, the argument `EQFilterResponse.swift:144-148` already makes about the Nyquist clamp.

**`mode` defaults to 0 = off on all four bands**, so a freshly added Dynamic EQ is **bit-exact
transparent**. That mirrors `.eq` (a fresh EQ does nothing,
`Sources/DAWEngine/Effects/EQEffect.swift:24-30`) and it makes the neutrality gate the *default*
render rather than a special configuration. The discoverability cost is real and is paid in
`fx.describe` prose and, if the preset table is the right home, a starting preset (§0 assumption 4).

**Deliberately NOT included, each with its reason:**

- **`kneeDb`** — fixed at the compressor's own default of **6 dB**, hard-coded. Saves 4 slots. A
  per-band knee is a control almost nobody moves and its absence is invisible; its presence would
  make the card 12 controls wide.
- **`mix`** — a dynamic EQ's wet/dry IS the band gain. A second blend stage would be a confusing
  duplicate, and `.djFilter` already set the precedent of a kind that deliberately has no `mix`
  (`Sources/DAWAppKit/EffectEditorModel.swift:262-269`).
- **per-band `enabled`** — `mode == 0` is the bypass, and it is a *true* no-op (the section is not
  even stepped), which is strictly better than a gain-0 bypass.
- **`shape`** — §4.1.
- **lookahead** — §6.

### 4.3 The gain law, written out completely

Per band `b`, per frame. `T = bandThresholdDb`, `R = bandRatio`, `Rg = bandRangeDb`, knee `K = 6`.

```
1. side-path, per channel c:
       s[c] = Biquad_b[c].step(x[c], bandPass(freq_b, q_b, fs))
       if !s[c].isFinite { bank_b.clearAll(); s[c] = 0 }        // guard AT THE CALLER
       peak = max(peak, |s[c]|)                                  // stereo-LINKED

2. peak follower (CompressorEffect.swift:471-472, verbatim semantics):
       level = max(peak, level * detectorDecay)                  // detectorDecay = exp(-1/(0.005*fs))
       if level < 1e-20 { level = 0 }

3. band level in dB (CompressorEffect.swift:474):
       L = 20 * log10(max(level, 1e-9))

4. distance past the threshold, SIGN-NORMALISED so `over > 0` always means "triggered":
       over = (mode == .above) ? (L - T) : (T - L)

5. depth, a NON-NEGATIVE magnitude, via the compressor's quadratic soft knee
   (CompressorEffect.swift:477-484) with k = 1 - 1/R   [note: k >= 0, the NEGATION of the
   compressor's `slope = 1/ratio - 1`, because `depth` here is a magnitude]:
       if      2*over <= -K   { depthRaw = 0 }
       else if 2*over >=  K   { depthRaw = k * over }
       else                   { t = over + K/2; depthRaw = k * t * t / (2*K) }
       depth = min(depthRaw, |Rg|)

6. signed target:
       targetDb = (Rg > 0 ? +1 : (Rg < 0 ? -1 : 0)) * depth

7. ballistics — ⛔ NOT the compressor's line:
       coeff = (|targetDb| > |env|) ? attackCoeff : releaseCoeff
       env   = coeff*env + (1 - coeff)*targetDb
       if |env| < 1e-10 { env = 0 }                              // TWO-SIDED snap

8. apply — ⛔ A REAL BRANCH, NOT A MULTIPLY BY ZERO:
       gMinus1 = pow(10, env/20) - 1
       if gMinus1 != 0 { for c: x[c] = Float(Double(x[c]) + gMinus1 * s[c]) }
```

Four points in that listing are non-obvious and each one is a bug waiting for a builder who
copies `CompressorEffect` line-for-line.

- ⛔ **Step 7 is NOT `targetDb < env`.** The compressor's test (`CompressorEffect.swift:487`) reads
  "attack when the reduction deepens" and is correct *because its target is always ≤ 0*. With a
  signed `rangeDb`, a boost band's target grows **upward**, and the compressor's comparison would
  give it attack and release backwards. `|targetDb| > |env|` is correct for both directions, and
  crossing zero (possible when `rangeDb` is automated through 0) correctly reads as release-then-
  attack. **Same reason the rest-snap at `:489` must become two-sided**: `env > -1e-10` would
  never snap a boost band to rest, leaving a permanent sub-dB lift.
- ⛔ **Step 8 must be a branch.** `x += 0.0 * s` is not a no-op: for `x == -0.0`, IEEE-754
  round-to-nearest gives `-0.0 + 0.0 = +0.0`, which is a **different bit pattern**. On silent or
  near-silent frames that is a byte-gate failure with no audible cause, and it is exactly the class
  of defect the "branch goes OUTSIDE the arithmetic" law exists to prevent. The branch also has to
  be *only* around the add — **the filter is still stepped**, because it has memory.
- ⚠️ **Step 5 uses the compressor's ratio law in BOTH modes.** A builder who knows expanders will
  expect `(R − 1)·(T − L)` for the below-threshold case and may "fix" it. That is a deliberate
  choice: one law, one set of tests, and a `ratio` control that means the same thing in both modes
  for a user who is not a dynamics specialist. **Write the reason at the call site.** If the
  audio-dsp-engineer disagrees on musical grounds, that is a legitimate design escalation — but it
  must be a decision, not a silent substitution.
- ⚠️ **Step 1's NaN guard now protects the AUDIO, not just a detector.** `m39-ae`'s guard
  (`CompressorEffect.swift:442-456`) exists because a poisoned recursive filter never recovers;
  there, a poisoned detector meant a dead de-esser. **Here `s[c]` is summed into the output buffer**,
  so a poisoned side-path writes NaN into the mix. Same guard, strictly higher stakes. Clear the
  whole bank, exactly as the compressor does, and pin it with the
  `CompressorDeEssTests.nanInputDoesNotPoisonTheDetector` analogue.

### 4.4 ⚠️ The `m39-ae` framing does NOT transfer, and the reason latency is still zero is different

The brief says: *"the filter hangs on the DETECTOR while the audio path is untouched, so it adds
zero latency."* That is an accurate description of `m39-ae` (`CompressorEffect.swift:13-21`) and it
**does not describe this design**. Here the side-path output **is summed into the audio**. The audio
path is touched by construction — that is what an EQ is.

**Latency is still exactly zero, for a different reason:** every section is a minimum-phase IIR
biquad with no delay line and no lookahead. Such a filter has frequency-dependent *group delay* — a
Q-2 bell at 1 kHz delays energy near 1 kHz by a fraction of a millisecond — but group delay is not
reportable latency and PDC neither can nor should compensate it. `.eq` has exactly the same property
today and reports `latencySamples { 0 }` (`EQEffect.swift:123`).

**What DOES transfer from `m39-ae`, and should be reused rather than paralleled:** the detector
machinery itself — the `Biquad`/`InlineBiquads` primitive, the peak follower with its fixed 5 ms
decay, the soft-knee gain computer, the one-pole smoother, the coefficient cache with its NaN seed,
the clear-on-exit rule, and the discipline of putting the branch outside the arithmetic. Those are
§4.3 steps 1-2 and 5-7 almost verbatim.

---

## 5. Q4 — DETECTOR SOURCE PER BAND

**Recommendation: the band's own side-path output, `s[c]`. Band-filtered, feed-forward,
stereo-linked, and free.**

The side-path filter already computes the band-isolated signal in order to apply the gain. Reading
the detector off the same samples costs **nothing** — no second filter, no second bank of state, no
second set of coefficients to keep in sync. This is the single most elegant property of the
topology and it is the reason to prefer it over any design that filters a separate detector copy.

Three consequences to record:

1. **`thresholdDb` means dBFS *at the band centre*, at every Q.** That is guaranteed by
   `bandPassSection` being the constant-0-dB-**peak** form, and it is precisely the argument the
   function's own doc comment already makes for its one existing caller
   (`Sources/DAWCore/EQFilterResponse.swift:134-142`). With the constant-skirt form, widening a band
   would silently lower its effective threshold. **Do not switch forms.**
2. **Feed-forward, not feedback.** `s[c]` is derived from the band's *input*. A feedback detector
   (reading the band's output) would be self-stabilising but makes `ratio` mean something else and
   makes the unit's behaviour depend on its own gain history. Rejected.
3. **Series cascade means band *b*'s detector sees bands 1…*b*−1's output** (§1). Document it.

### Broadband detector — REJECTED for v1

A broadband detector ("duck 3 kHz whenever the *whole mix* gets loud") is a real and different
effect, and it is what a mastering engineer sometimes wants. It would cost one more param per band
(`detectorSource`) and a second, unfiltered peak follower. **Rejected because the band-filtered
detector is what "dynamic EQ" means to every competitor cited in `m23-cl`**, and because the
broadband case is already achievable today: `.compressor` with `detectorMode` off, keyed or not.
Filed as a future append (4 slots), not built.

### External sidechain key — REJECTED for v1, with the cost stated honestly

The sidechain whitelist is `guard kind == .compressor || kind == .gate`
(`Sources/DAWCore/ProjectStore.swift:3446`). Widening it is one line — **and that one line buys
nothing**, which is the exact lesson `docs/research/2026-09-19-plugin-program-inventory.md` §7
records against the "ducked reverb is almost free" claim. The real work is:

- conforming to `KeyableEffectRendering` and threading the key buffers through four band loops;
- a genuine design question the guard does not answer: **does the key get band-filtered per band?**
  If yes, that is 4 more `InlineBiquads` banks and 4 more coefficient sets, and the key's band must
  track each band's own `freq`/`Q` (or not — another decision). If no, every band shares one
  broadband key and `thresholdDb` stops meaning dBFS-at-centre;
- the strip-level constraints (one key per strip, non-bus sources only) become sharper when one
  insert wants four differently-filtered views of the same key.

**That is a design spike of its own, not plumbing.** File it; do not smuggle it into this build.

---

## 6. Q5 — LATENCY

**Target: exactly zero. `var latencySamples: Int { 0 }`, a literal, at every setting of every
parameter.** No shape proposed here adds any.

This is not incidental; it is a constraint the design was chosen to satisfy, and it has a
consequence that must be written into the source: **because latency is constant, no parameter is
refused an automation lane for the `m39-ad` reason.** All 32 slots accept lanes and the guard is
`(0...31)`.

`Sources/DAWCore/Automation.swift:116-132` is the place that reasoning lives for the saturator, and
its own comment already spells out the asymmetry with `.clipper`: *"the refusal is about the
LATENCY, not about the name."* The `.dynamicEQ` entry in that file is therefore **no entry at all** —
and a comment in the new kind's header should say why, so the next reader does not assume the
omission was an oversight.

### Lookahead — explicitly REJECTED for v1

Some professional dynamic EQs offer a short lookahead so the band is already moving when a transient
arrives. It would be 1-5 ms of delay on the audio path.

**Rejected, and the precedent is `m39-ad`.** A lookahead control makes `latencySamples`
**parameter-dependent**, which forces (a) a PDC plan rebuild on every parameter pass, and (b)
refusing that param an automation lane — because `storeAutomatedParam` runs on the render thread and
cannot rebuild the main-actor PDC plan, leaving it stale **with every test still green**
(`Automation.swift:116-123`). That is a large, subtle cost for a feature nobody has asked for. If it
is ever wanted it should arrive as a deliberate item that re-reads `m39-ad` first.

---

## 7. Q6 — ABOVE / BELOW, AND HOW THE GAINS COMPOSE

### Above vs below: one `mode`, one signed `rangeDb`, four behaviours

`mode` selects **which side of the threshold triggers the band**; the **sign of `rangeDb`** selects
**which way the band then moves**. Two params, four musically distinct behaviours:

| `mode` | `rangeDb` | Behaviour | The move it is for |
|---|---|---|---|
| 1 `above` | negative (**default**) | Cut the band when it gets loud | De-ess, de-harsh, tame a boxy 300 Hz, control a resonant snare ring |
| 1 `above` | positive | Boost the band when it gets loud | Exaggerate a transient's brightness; "upward" excitement |
| 2 `below` | positive | Boost the band when it gets quiet | Restore air on a quiet passage; bring up a weak low end under a fade |
| 2 `below` | negative | Cut the band when it gets quiet | Downward expansion in one band — clean up mic rumble between phrases |
| 0 `off` | — | **Section is not stepped at all.** True no-op | The default |

This is why `rangeDb` is signed rather than a magnitude with a separate direction toggle: two
controls instead of three, and the sign carries a meaning a novice reads immediately ("minus means
it turns it down").

### How static EQ gain and dynamic gain compose: **they do not, and that is deliberate**

`.dynamicEQ` bands have **no static gain parameter**. A band at rest is exactly flat.

**Rejected alternative — a per-band `gainDb` plus a dynamic offset (the FabFilter Pro-Q model),
composing as `G_total = G_static · G_dyn`, i.e. additive in dB.** It is the industry-standard shape
and it is genuinely convenient. Rejected for v1 for three reasons:

1. **4 more slots** (32 → 36), on the kind that would already be the tree's largest.
2. **It breaks the free neutrality.** With a static gain the band's section is never exactly `H = 1`,
   so it must be stepped even at rest, so the transparency null stops being free and starts needing
   a special case.
3. **`.eq` already exists and is a better static EQ than this kind's bells would be** (RBJ,
   constant half-gain bandwidth, shelves, HP/LP, 24 dB/oct slopes, a curve editor). The
   one-command-surface answer is "chain `.eq` → `.dynamicEQ`", which works today with zero new code,
   and which keeps each kind honest about what it is. **This kind is the dynamic half, and says so.**

If the user later wants Pro-Q-style combined bands, `gainDb` is a clean 4-slot append at 32-35 and
the composition is a single extra multiply. Filed, costed, not built.

---

## 8. Blast radius — measured, not estimated

### The 9 `case .<kind>` sites

Measured by `grep -rn "case \.clipper" Sources` and `case \.bitCrusher` (two independent kinds,
identical result), then reading each enclosing function and checking for a `default:` arm.

| # | File:line (for `.clipper`) | Enclosing function | Compiler-forced? |
|---|---|---|---|
| 1 | `Sources/DAWEngine/Effects/EffectFactory.swift:66` | `makeInstance(for:)` (:24) | ✅ yes |
| 2 | `Sources/DAWEngine/Effects/EffectFactory.swift:121` | `applyParams(_:to:)` (:78) | ✅ yes |
| 3 | `Sources/DAWAppKit/EffectEditorModel.swift:401` | `groupTable(for:)` (:150) | ✅ yes |
| 4 | `Sources/DAWAppKit/MixerModel.swift:147` | `effectDisplayName(_:)` (:99) | ✅ yes |
| 5 | `Sources/DAWCore/Effects.swift:5234` | `EffectParamSpec.specs(for:)` (:3614) | ✅ yes |
| 6 | `Sources/DAWCore/Effects.swift:5638` | `EffectDescriptor.paramValue(_:)` (:5400) | ✅ yes |
| 7 | `Sources/DAWCore/ProjectStore.swift:3966` | `applyEffectParam(_:name:value:)` (:3643) | ✅ yes |
| 8 | `Sources/DAWControl/Commands.swift:10850` | `effectParamsJSON(_:)` (:10450) | ✅ yes |
| 9 | `Sources/DAWCore/ProjectStore.swift:3279` | `effectDisplayName(_:)` (:3251) | ⛔ **NO — `default:` at :3280** |

⭐ **Site 9 is the one that ships a wrong answer silently.** Its `default:` arm is
`kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()`, which turns `dynamicEQ` into
**"DynamicEQ"** — plausible enough to survive review, wrong in the undo label and every store-side
display. The file's own comments at `:3262` and `:3273` record that m39-y and m39-ac each hit
exactly this. **Both display-name functions (sites 4 and 9) need an explicit `"Dynamic EQ"` arm.**

This reconciles the memory note that says "EIGHT per-kind sites": **8 compiler-forced + 1
defaulted = 9 `case` arms.** Both numbers are right about different things.

### The non-switch touch points (compiler will NOT catch most of these)

| File | What |
|---|---|
| `Sources/DAWCore/Effects.swift` | `EffectDescriptor.Kind` case; the `dynamicEQ: DynamicEQParams?` field; its `CodingKeys` entry; `resolvedDynamicEQ`; the `DynamicEQParams` struct itself |
| `Sources/DAWCore/ProjectDocument.swift:763,779,811,842,875,900` | the persisted document mirror — field, coding key, mirror-in, decode, encode, mirror-out. **Six edits in one file** |
| `Sources/DAWCore/MixerPresets.swift:73` | preset `EffectDescriptor` construction |
| ⚠️ `Sources/DAWApp/Mixer/MixerStripView.swift:8-14` | `addableEffectKinds` — **HAND-MAINTAINED; its own comment says the compiler cannot catch the omission.** Omit it and the effect is invisible in the "+" menu |
| ⚠️ `Sources/DAWCore/MediaImporting.swift:601-604` | `masterChainBuiltInOnly`'s hand-listed kinds. **The exact wording is CONTRACT (design-m13d §4), surfaced verbatim over the wire and MCP and gate-checked in C6.** Appending `|dynamicEQ` changes gate-checked text |
| `Sources/DAWControl/CopilotCatalog.swift:1000` | the copilot's kind list |
| `Sources/DAWAppKit/EffectHonestyNote.swift:83-103` | the honesty verdict — land in the no-note arm alongside `.eq` (§2) |
| `mcp-server/src/server.ts:4297-4305, 4894, 10488-10489` | three hand-maintained kind enumerations + a description block |
| **NEW** `Sources/DAWEngine/Effects/DynamicEQEffect.swift` | the render implementation |

**Total ≈ 18 files.** No new wire verb; no new MCP tool. `fx.add` and the master-chain add parse
the kind generically (`Sources/DAWControl/Commands.swift:2753`, `:9688`), and `fx.setParam` /
`fx.describe` are name-driven off `specs(for:)`. **The 227-command and 232-tool pins do not move,
and `scripts/gates/doc-count-drift.mjs` needs nothing.**

---

## 9. Render-thread contract and state layout

**The contract:** `process()` / `reset()` / `prepare()` / `storeAutomatedParam()` allocate nothing,
take no locks, log nothing, touch no ObjC. Per-sample work is pure arithmetic plus `log10`/`pow`
(libm, the compressor's existing budget). Coefficient trig runs only on parameter adoption.

### State

```
maxChannels = 8, bandCount = 4

bank0…bank3 : InlineBiquads           // one bank PER BAND, indexed BY CHANNEL
                                      //   (`InlineBiquads` holds 8 → 4 banks cover 4×8 = 32 sections)
coefficients: 4 × (b0,b1,b2,a1,a2)    // 20 stored Doubles, or a 4-element fixed tuple of a POD struct
cache       : 4 × (lastFreq, lastQ, lastMode)  + lastRate   // NaN-seeded, CompressorEffect.swift:102-107
env         : 4 × Double              // smoothed band gain in dB
level       : 4 × Double              // peak-follower state
attackCoeff / releaseCoeff : 4 × Double each
detectorDecay, preparedChannels, sampleRate, lastGeneration
overlay     : AutomationParamOverlay<DynamicEQParams>
```

### Loop nesting — band-outer, then frame, then channel

```
gather channel pointers into InlineChannelPointers          (CompressorEffect.swift:362-373)
for band in 0..<4 where bandMode[band] != .off {
    var f = bank(band)                 // ONE switch: copy 8 Biquads (16 Doubles) into a local
    for frame in 0..<minFrames {
        for c in 0..<channelCount { s[c] = f.step(c, ...); guard finite; peak = max(...) }
        ...steps 2-7 of §4.3...
        if gMinus1 != 0 { for c in 0..<channelCount { data[c][frame] += gMinus1 * s[c] } }
    }
    setBank(band, f)                   // ONE switch back
}
```

Three deliberate choices in that sketch:

- **Band-outer is required by the series cascade** (§1) and is free: band `b+1` simply reads the
  buffer band `b` just wrote.
- **Hoisting the bank into a local once per band per block** keeps the inner loop to a single
  `switch` (on channel, inside `InlineBiquads.step`) instead of a nested one (band × channel).
  Copying 16 Doubles four times per quantum is negligible and is not an allocation.
- **`s[c]` must survive between the two channel loops**, so it needs fixed-size stack storage for 8
  `Double`s. **Declare it PRIVATE in `DynamicEQEffect.swift`, not as a shared primitive.** The
  tree's extraction law is explicit: `Biquad` became a primitive when its **second** caller appeared,
  "not before and not on spec" (`Sources/DAWEngine/Effects/Primitives/Biquad.swift:8-13`). One
  caller, one private struct.

### Coefficient derivation

`deriveRenderParams(p)` recomputes all four bands, **each guarded by its own cache** so that an
automation lane riding `band1ThresholdDb` — which routes through the same function — costs twelve
comparisons and **no trig**. This is `CompressorEffect.swift:287-292` replicated four times, and
without it a single threshold lane would pay 4 × `sin`/`cos` per store.

### Band lifecycle — ⛔ clear MORE than the compressor does, and clear it on EXIT

`bank(band).clearAll()` on **mode exit**, never on entry — `CompressorEffect.swift:270-280` states
the reason exactly (clearing on entry would restart the filter from silence on every automated
`0→1→0→1` flutter and click).

⛔⛔ **But the compressor's rule is NOT sufficient here, and copying it verbatim ships a step.**
There, `detectorMode` gates only the detector *filter*; the envelope keeps running either way. Here
`mode` gates **the whole band**. A band that goes off holding `env[band] = −6` and comes back
applies −6 dB in-band **on its very first frame** — an instant 6 dB step in one band, which is a
click, and which an automated `off → above → off → above` flutter repeats. **On mode exit, zero
`env[band]` and `level[band]` as well as the filter bank**, so re-entry starts at rest and attacks
through its own `attackMs` like everything else.

⚠️ **A `mode` change from 1 to 2 (above ↔ below) must NOT clear anything.** The coefficients are
identical (they depend only on `freq`/`Q`/`fs`) and the band never stopped running; clearing would
click for no reason. The test is *"did the mode leave `off`"*, not *"did the mode change"* — a
builder generalising `deriveDetectorFilter`'s `lastDetectorMode != .off` check
(`CompressorEffect.swift:278`) into "any mode change clears" gets this wrong.

`prepare()` clears all four banks, **zeroes all four `env` and `level`** (the compressor does the
same for its single pair at `CompressorEffect.swift:180-181`) and NaN-poisons `lastRate` so the next
derive cannot decide nothing changed (`CompressorEffect.swift:186-191`). `reset()` does the same
minus the rate poison (`CompressorEffect.swift:207-213`) — a transport stop must not leave a band
holding 6 dB of reduction into the first frame after the restart.

### `storeAutomatedParam(slot:value:)`

`guard value.isFinite, (0...31).contains(slot)`. Decompose `band = slot / 8`, `p = slot % 8`, poke
the overlay, re-derive. **Every field must be re-guarded and re-clamped inside the derive**, because
an overlay poke bypasses `DynamicEQParams.init`'s clamping — the trap
`CompressorEffect.swift:247-261` spells out, and specifically: `mode` needs an `isFinite` guard
before any `Int()` conversion (which **traps** on NaN), and `freq` needs clamping to the declared
range before it reaches `bandPassSection`'s `min(freq, sampleRate * 0.49)`.

### Gain-reduction metering — v1 does NOT conform to `GainReductionReporting`

`CompressorEffect` conforms and publishes **one** number through one atomic slot
(`CompressorEffect.swift:114-122`, `:151-155`). A four-band unit has four movements. A max-of-bands
would publish a number that cannot say **which** band moved — and the mixer draws it exactly as it
draws a compressor's, so the meter would be confidently wrong rather than absent.

**Recommendation: do not conform in v1. File per-band GR as a named follow-up** requiring a
protocol widening (`GainReductionReporting` → an indexed read, or a second protocol).

⚠️ **This is the weakest point of the v1 design and the builder should know it.** A dynamic effect
with no visible feedback is hard to trust. Two mitigations exist today and both should ship:

- **Agents already have a way to see it.** `fx.spectrum` (m23-r4) exposes a per-insert spectrum over
  the wire, so an agent *can* measure a band moving — cited in
  `docs/research/2026-09-19-plugin-program-inventory.md` §7 as already-shipped capability.
- **Humans get the listening fixture** (§10 G6), which is mandatory anyway.

If the user would rather have a single honest "deepest band" meter than none, that is a legitimate
call — **but it is theirs, not mine.** Offer it; do not assume it.

---

## 10. Acceptance gates

Nine gates. G1-G4 are non-negotiable; G5-G9 are how this tree has learned to catch the things unit
tests do not.

### G1 — The transparency null (the analogue of `eqNeutralSettingsAreTransparent`)

**Config 1 — all four bands `mode == 0`.** Must render **`max |wet − dry| == 0`** — bit-exact, not
"within epsilon" — over a signal containing silence, DC, full-scale transients, **and negative
zero**. The `-0.0` case is the point: it is what distinguishes a real branch from `x += 0.0 * s`
(§4.3 step 8).

**Config 2 — a band ON but genuinely below its knee.** Also bit-exact, because
`env == 0 → pow(10,0) == 1 → gMinus1 == 0` exactly. ⚠️ **This configuration is easy to specify
wrong and will fail as "threshold at 0 dB, so it never triggers".** Two reasons, both arithmetic:

- **The 6 dB knee starts working BELOW the threshold.** `depthRaw` is zero only while
  `2·over ≤ −K`, i.e. `L ≤ T − K/2 = T − 3 dB`. At `over == 0` exactly (signal level *at* the
  threshold) the knee gives `t = 3`, `depthRaw = 0.75 · 9 / 12 = **0.5625 dB**` at ratio 4 — a real,
  non-null reduction. And because `bandPassSection` has **exactly 0 dB peak gain** (measured,
  §0), a full-scale sine at `f_c` presents `L = 0 dBFS` in-band. So a G1 fixture containing
  "full-scale transients" plus a band at threshold 0 is **not** a null. **Specify it properly:
  `mode = above`, threshold 0 dBFS, and the fixture's in-band peak held at or below −3 dBFS** —
  or, better, assert the knee arithmetic explicitly as a separate test rather than hiding it
  inside a null.
- ⛔ **`mode = below` can never be "not triggered", and that is by design.** On digital silence
  `level → 0 → L = 20·log10(1e-9) = −180 dBFS`, so `over = T + 180` and the band sits at its full
  `|rangeDb|`. That is what an expander does to silence and it is correct — but it means **Config 2
  must be `above` only**, and the `below` behaviour on silence needs its own documented test so a
  builder does not file it as a bug.

### G2 — ⛔⛔ The TWO GUARDS, correctly scoped for a NEW kind

The tree's law is that "bit-exact for existing projects" needs **both** a decode test **and** a byte
gate, and that they are not interchangeable — proven by plant this cycle: a planted
`?? 0` → `?? 1` on a *decode default* passed the byte gate (exit 0, **MISSED**) because the demo
harness builds params through `fx.add` → the **memberwise** init, so `init(from:)` never runs; a
planted memberwise `= 0` → `= 1` was caught (exit 1).

**Scoping that honestly for a kind that has never shipped:**

- **Guard A (decode).** `DynamicEQParamsTests` must assert (i) `decode(encode(DynamicEQParams()))`
  equals `DynamicEQParams()` **field by field**, all 32, and (ii) that decoding a JSON **missing any
  required key THROWS**. ⭐ (ii) is the stronger v1 form: **v1 ships with all 32 fields required and
  synthesized `Codable` — no custom `init(from:)`, therefore no `??` to drift.** The test is what
  freezes that property.
- **Guard B (byte).** `scripts/gates/m39XX-dyneq-bytes.mjs` over a new
  `scripts/demos/specs/dyneq.json` with **≥ 4 variants**, hashes pinned from the landing build,
  exiting `checks.length > 0 && checks.every(ok) ? 0 : 1` (the `m23-fa` verdict rule — 57 of 71
  gates once exited 0 after running zero checks).
- ⛔ **The non-interchangeability plant is OWED AT THE FIRST v2 APPEND, and the design must say so
  rather than claim it now.** The moment `.dynamicEQ` gains its first additive optional (a `shape`,
  a `gainDb`, a `detectorSource` — §4.1, §5, §7), it inherits the `EQParams` v2 pattern
  (`Sources/DAWCore/Effects.swift:431-452`: additive optionals, nil omitted on disk, `resolved*`
  accessors) and **acquires a decode default that the byte gate is blind to.** That is the moment
  to re-run the plant in both directions and record the result. Claiming the pair is proven now,
  when v1 has no decode default to plant on, would be an assumption dressed as a measurement.

### G3 — The physics, not the headline metric

⛔⛔ Three laws this tree has paid for, applied here:

1. **Identical bytes prove the axis did nothing; distinct bytes prove nothing.** Every variant pair
   must be asserted against a **predicted physical quantity**, not merely "they differ".
2. **The boring invariance controls catch the bug.** Specifically required:
   - **out-of-band invariance:** with band 2 at 3 kHz triggering hard, a 200 Hz tone's RMS must be
     unchanged to within the filter's own out-of-band leakage, **with the figure measured and
     written into the test** rather than asserted as "unchanged";
   - **channel-order invariance:** rendering L/R swapped and swapping back must be bit-identical —
     this is what proves the detector is genuinely stereo-linked and that no band shares one filter
     section between channels;
   - **`mode == off` invariance:** a band whose `freq`/`Q`/`threshold` are swept wildly while
     `mode == 0` must produce byte-identical output (proves the section is not being stepped).
3. **Audibility is not correctness.** Five planted defects have passed `audible=true` in this tree.
   No gate here may rest on audibility.

### G4 — The response pin (predicted vs rendered), the `EQResponsePinTests` shape

A static prediction of the side-path magnitude response — `20·log10|1 + (G−1)·H_BP(f)|`, computed
from the same `EQFilterResponse.bandPassSection` coefficients — must match the **rendered** sweep
at a held gain. This is the gate that would catch a builder substituting the constant-skirt
band-pass form, or the RBJ peaking form, or an algebraic "cleanup" of the side-path sum.

It must also **pin the measured Q-shape difference from `.eq`**, because that difference is a
deliberate design choice and a future reader will otherwise file it as a bug:

> At `f = 1 kHz`, `Q = 2`, `fs = 48 kHz`: `.eq`'s RBJ peaking band has a half-gain bandwidth of
> **499.3 Hz at +3, +6, +12 and +18 dB** (constant). The side-path band's is **592.5 / 705.1 /
> 994.4 / 1402.2 Hz** at those gains. Both reach exactly the requested gain at `f`.

### G5 — Render-thread safety review, by hand

No allocation, no locks, no ObjC, no logging in `process`/`reset`/`storeAutomatedParam`/the derive.
Specific things to look for, each of which has bitten this tree: a `[Biquad]` array subscripted
inside the sample loop (a CoW check per sample — `Biquad.swift:80-82`), a whole-array reassignment
instead of element-wise writes (`EQFilterResponse.swift:254-257`), and an `Int()` conversion on a
possibly-NaN param (traps — `CompressorEffect.swift:252-255`).

### G6 — The listening fixture, with its separation MEASURED FIRST

⛔⛔ The `m39-ae` law, verbatim in consequence: **a listening fixture's load-bearing number is the
SEPARATION between what the effect targets and what it must leave alone, and it must be measured
BEFORE the axis is chosen.** The de-esser's first cut used a sawtooth voice where the sibilant blip
was only **5.5 dB** above the sustained notes inside the detector band, so every threshold that
caught the blip also ducked the vowels — and all four variants rendered, measured `audible=true`,
and came out byte-distinct while the prose claimed the opposite. The retuned fixture reached
**33.1 dB** of separation.

Do the same here: build the source so the band the dynamic EQ targets is far above what it must not
touch, **measure that number, and put it in the doc**. Ship **3-4 variants differing on ONE axis
each** (the user's standing rule) — `mode` off/above, `rangeDb` depth, `attackMs`, `Q` — never one
result.

#### ✅ MEASURED RESULT (m39-af close, 2026-09-20)

**Separation: 16.9 dB** — how much louder 3 kHz is during a chord stab than in the gap between
stabs, in the **source itself** (eight three-note stabs, C3+C4+G4 on a saw pad, 8 s at 120 BPM;
`scripts/demos/specs/dyneq.json`). Comfortably clear of the 5.5 dB that made the de-esser's first
fixture unusable. Five variants rendered, **four shipped** on one axis (what the band does):
`control` / `boost` / `cut` / `below`. The fifth (`cut-6`) was dropped on measurement — it sat
**0.1 LUFS** whole-file and 1.14 dB in-band from `cut-18`, which is the same take twice, not a
choice.

⛔⛔ **AND THE INSTRUMENT ALMOST INVENTED A DEFECT — A NEW LAW, NOT A FOOTNOTE: MATCH THE
INSTRUMENT'S TIME CONSTANT TO THE EFFECT'S.** The first verification of the headline claim (does
the band rest when the music rests?) used `ebur128` MOMENTARY and reported loud and quiet windows
treated **0.01 dB** apart — i.e. "this is behaving like a STATIC cut", a defect against a build
that was fine. **The instrument could not have said otherwise: momentary is a 400 ms sliding
window and the band's release is 80 ms**, so a gain that dips and recovers *inside* one window is
reported as a constant average. Re-measured with short-time RMS on a **10 ms** hop (8× faster than
the release): `boost-12` separates loud from quiet windows by **3.12 dB** and sits at **+0.70 dB**
at rest before the first stab, which is the whole claim. ⭐ **The tell was that the number was too
tidy** — the control's own band level swung ~14 dB between windows while the "difference" sat
pinned to two decimals. Both hypotheses predicted that observation, so the observation was not
discriminating, and a verdict drawn from it would have been a coin toss dressed as a measurement.

⚠️ **One variant is honestly weak and the demo copy says so:** `cut-18` separates loud from quiet
by only **0.83 dB**, because its threshold (−43 dBFS) sits low enough that the band works nearly
all the time. That is a **fixture-settings** fault, not a DSP fault — the same binary produces
3.12 dB on `boost-12`. Left as shipped rather than silently retuned, and labelled as the weaker
demonstration on the handoff page.

⛔ **Deliberately NOT rendered: a matched static-`.eq` comparison.** `.eq`'s `Q` and
`.dynamicEQ`'s `Q` are different bandwidths for the same number (§4), so a "matched-Q" A/B would
look fair and not be. The 10 ms time series proves the same claim without the trap.

### G7 — A CPU benchmark, because §0 assumption 2 is an estimate

Measure per-sample cost at 48 kHz, 2 channels, 4 bands active, against `.eq` and `.compressor` as
controls. ⭐ **`docs/research/2026-09-19-plugin-program-inventory.md` §11 is the cautionary tale: a
verified mechanism is not a verified cost, and a 16× ratio on an unmeasured base read as decisive
until someone measured the base at 12 ns.** Do not let my "~4× the compressor" into the close note
unmeasured.

### G8 — The editor card, looked at by a human or a pixel probe

⭐ **A UI phase is not done until someone looked at it**, and no gate in this tree can see a pixel
except `debug.captureUI` + `scripts/probes/m23g1-clip-box-probe.swift`. Capture the insert editor
with a `.dynamicEQ` on a strip. **Named fallback if 4 groups of 8 does not fit: drop to 3 bands
(24 slots).** The per-band block is identical either way, so this is a genuinely late-binding
decision — but it must be made by looking, not by hoping.

#### ✅ LOOKED AT (m39-af close, 2026-09-20) — `scripts/gates/_m39af-dyneq-card-probe.mjs`

17/17 mechanical checks green, and **two PNGs actually read by a human**, captured at 1400×1000
and at the 672 pt content floor (`WindowFloor.minWindowContentHeight`).

**THE FALLBACK IS NOT TRIGGERED. Ship 4 bands.** All 32 params reach the card as live values
(driven from `fx.describe`, not a hardcoded list), grouped band-major under `BAND 1`…`BAND 4`
headers, three knobs to a row. Bands 3 and 4 are **below the fold**; they are reachable **by
inference, not by observation** — `knobSections` is a `ScrollView`
(`EffectEditorOverlay.swift:302`), but **nobody has scrolled the card and SEEN band 4 drawn.** ⚠️
A static capture cannot tell "below the fold" from "unreachable", and the honest word is the
weaker one until someone scrolls it. ⭐ Dropping to 3 bands would NOT have fixed
what the capture shows: the constraint is a height CAP, so 3 bands would still show ~1.7 of them.
**Cutting a band would have cost a feature and bought nothing** — which is precisely why this
decision had to be made by looking.

⛔ **DEFECT FOUND, and it is the one that matters to a user: `bandNMode` renders as a KNOB
reading `0.00`.** The card labels it `LISTEN` and draws a continuous rotary whose readout is a
bare number, so **off / above / below is unreadable from the card** — the three-way switch at the
heart of this effect looks like a knob someone left at zero. The snapped truth already exists:
the wire echoes `bandNModeLabel` ("off"/"above"/"below") on every `fx.add`/`fx.setParam` result,
and the card simply does not show it. ⚠️ **NOT new and NOT confined to this kind** — the same
surface renders `compressor.detectorMode`, `clipper.mode`, `ringMod.waveform`, `phaser.stages`
and `saturator.oversampling` as knobs too. This kind did not create the debt; it multiplied it by
four on a single card, and is the first time anyone looked at it. **Fix belongs in the card
(render a discrete param as its label), never in the param layout** — moving slots would
invalidate the byte pins and the MCP docs for no user-visible gain.

⚠️ **Second, smaller: the height cap is hard-coded and window-independent.** `sectionsHeight`
returns `min(…, 460)` (`EffectEditorOverlay.swift:188`), so the card measured **340 × 571 at BOTH
window sizes** — at 1400×1000 it leaves ~400 pt of empty screen below itself while showing under
half the bands. That constant was written for the 22-param `.eq`; at 32 params it bites 45 %
harder. Not a correctness fault and not blocking.

### G9 — The existing sweeps must stay green without being special-cased

`InsertLabelBudgetTests` (`Tests/DAWAppKitTests/InsertLabelBudgetTests.swift:41-44`) sweeps
`Kind.allCases` and will fail if "Dynamic EQ" does not fit 85 pt. The `ParamCurve` conformance
suite and the `Modulatable` 31/18/15 split pin will both move by 32 and must be **re-pinned with
the new params NAMED**, not just re-totalled — ⚠️ **a net delta hides a shrink; make the
implementing agent name every count that moves.**

---

## 11. Implementation plan

Ordered so that each step is independently testable and nothing lands half-wired. **Route:
`audio-dsp-engineer`** (steps 2-4 are the DSP; 1 and 5-8 are mechanical and could be split off to
`swift-app-engineer` / `mcp-integration-engineer` if the agent's context is tight).

**Step 1 — DAWCore model.** `Sources/DAWCore/Effects.swift`: add `case dynamicEQ` to
`EffectDescriptor.Kind`; add `public struct DynamicEQParams` (32 required `Double`s, clamped on
init, synthesized `Codable`, explicit `CodingKeys`); add the `dynamicEQ:` field + coding key +
`resolvedDynamicEQ` on `EffectDescriptor`; add the 32-entry arm to `specs(for:)` (§4.2) and the arm
to `paramValue(_:)`. **Ranges mirrored from existing constants, never re-spelled.**
→ Tests: `Tests/DAWCoreTests/DynamicEQParamsTests.swift` — G2 guard A, clamping, the range-mirroring
assertion, the 32-slot ordering pinned against literals.

**Step 2 — the render kind.** New `Sources/DAWEngine/Effects/DynamicEQEffect.swift` implementing
`EffectRendering`, per §9. Copy the atomic-POD-publish/retire-bin convention from
`CompressorEffect.swift:63-72`, `:131-149`, `:161-173`, `:219-226`.
→ Tests: `Tests/DAWEngineTests/DynamicEQRenderTests.swift` — G1 (both null configurations,
including `-0.0`), G3 (all three invariance controls), the gain law at known levels against
hand-computed dB, NaN-does-not-poison, `reset()` clears, sample-rate change re-derives.

**Step 3 — the response pin.** `Tests/DAWCoreTests/DynamicEQResponseTests.swift` — G4, including
the Q-shape difference table verbatim.

**Step 4 — factory + automation.** `EffectFactory.swift` sites 1-2; confirm **no** entry is needed
in `Sources/DAWCore/Automation.swift` and add a comment there saying why (§6).
→ Tests: `Tests/DAWControlTests/AutomationCommandTests.swift` additions — a lane on each of the 32
slots resolves and is **not** inert; the `(0...31)` guard rejects 32.

**Step 5 — persistence + presets.** `ProjectDocument.swift` (6 edits), `MixerPresets.swift`.
→ Tests: `Tests/DAWCoreTests/EffectDocumentMirrorTests.swift` additions — round-trip through the
document mirror, all 32 fields.

**Step 6 — control plane.** `ProjectStore.applyEffectParam` (site 7), **both** display-name
functions (sites 4 and 9 — §8), `Commands.effectParamsJSON` (site 8), `CopilotCatalog.swift`,
`MediaImporting.swift`'s contract string.
→ Tests: `Tests/DAWControlTests/FXCommandTests.swift` additions — `fx.add {kind:"dynamicEQ"}`,
`fx.setParam` by name with clamp-and-warn, `fx.describe` returns 32 specs with notes, and the
display name is **"Dynamic EQ"** not "DynamicEQ". ⚠️ The `masterChainBuiltInOnly` text is
gate-checked in C6 — update the gate's expectation in the same commit or it fails.

**Step 7 — UI.** `EffectEditorModel.groupTable` (site 3, four groups `BAND 1`…`BAND 4` with spelled-
out labels — "Listen Above/Below", "Threshold", "Range", not raw param names, the `m39-ae` DE-ESS
precedent at `EffectEditorModel.swift:180-200`); `MixerStripView.addableEffectKinds`;
`EffectHonestyNote`.
→ G8 pixel check.

**Step 8 — MCP.** Three enum edits + a description block in `mcp-server/src/server.ts`. **No new
tool.** Description must carry: bells-only, the Q caveat, `mode`/`rangeDb`'s four combinations, zero
latency, no GR meter but `fx_spectrum` works, and the **shared 64-lane/route budget** note (§3).
→ `mcp-server/test/` additions; `node scripts/gates/doc-count-drift.mjs` should be **unchanged** at
227/232 — if it moves, something grew a verb that should not have.

**Step 9 — gates + docs.** `scripts/demos/specs/dyneq.json`, `scripts/gates/m39XX-dyneq-bytes.mjs`,
the G6 listening fixture with its separation measured, `CHANGELOG.md`, and tick **`m23-cl` only
after stating in the bullet that the MULTIBAND half remains open** (the `m23-cm` failure — a shipped
feature whose checkbox stayed open through the cycle that closed it, caught only by accident, is
recorded at `docs/ROADMAP.md:1114`; do not invert it by ticking half an item).

### Nothing here requires full Xcode

No entitlements, no AUv3, no signing, no code-signed bundle. `swift build` + `./scripts/test.sh`
cover the whole item. (Xcode 26.6 is installed anyway, but this item does not need it.)

---

## 12. Rejected alternatives

Recorded so a future reader deciding whether to revisit has the reasoning, not just the verdict.

| Rejected | Why |
|---|---|
| **A crossover-based multiband dynamics engine** (split → process → sum) | It is the OTHER half of `m23-cl` and a genuinely different effect. It is what makes that item weight L. Nothing in a dynamic EQ needs it (§1) |
| **A mode on the shipped `.eq`** | Requires re-nesting `.eq`'s shipped render loop to stereo-link a detector, and puts two incompatible peaking topologies in one kind (§2). The `m39-ae` cheapness does not transfer |
| **RBJ peaking sections with gain-modulated coefficients on a stride** | Forces a control-rate decision (a second shape decision), pays `sin`/`cos`/`pow` per band per stride, and modulates a recursive filter's poles — the exact thing the side-path form makes unnecessary. It buys only shape-parity with `.eq`, which §2 argues is illusory anyway once dynamics are on |
| **Parallel band summation** | Overlapping bands sum rather than multiply, so the curve is not dB-additive and does not match `.eq`'s composition rule (§1) |
| **Shelf bands via a 2nd-order side-path low/high-pass** | ⛔ **Measured +0.82 dB boost at the corner while cutting 9 dB.** A defect |
| **Shelf bands via a first-order side-path section** | Clean (measured), but no `Q`, 6 dB/oct only, and asymmetric boost/cut — so the per-band block stops being uniform. Deferred as a costed append, not refused (§4.1) |
| **Per-band static `gainDb`** (Pro-Q model) | 4 more slots, destroys the free transparency null, and duplicates `.eq`, which is a better static EQ. `.eq → .dynamicEQ` works today (§7) |
| **Per-band `kneeDb`** | 4 slots for a control almost nobody moves. Fixed at 6 dB, the compressor's own default |
| **`mix` / dry-wet** | The band gain IS the wet/dry. `.djFilter` set the no-`mix` precedent (`EffectEditorModel.swift:268`) |
| **Lookahead** | Makes `latencySamples` parameter-dependent → PDC plan goes stale from a render-thread store with every test green. The `m39-ad` precedent (§6) |
| **Broadband detector option** | A different effect, already reachable via `.compressor`. Costed append (§5) |
| **External sidechain key in v1** | Widening the whitelist at `ProjectStore.swift:3446` is one line that buys nothing without the DSP — the §7 "ducked reverb" lesson. The real question (is the key band-filtered per band?) is its own spike (§5) |
| **Conforming to `GainReductionReporting` with a max-of-bands** | Publishes a number that cannot say which band moved, into a meter the mixer draws as a compressor's. Absent beats confidently wrong. Filed as a follow-up needing a protocol widening (§9) |
| **6 bands** | 48 slots; more than half a strip's 64-lane automation budget in one insert, and an editor card nobody can read. 4 matches every competitor `m23-cl` cites |
| **Extracting the 8-Double side-path carrier as a shared primitive** | One caller. `Biquad.swift:8-13` states the law: extract on the SECOND caller, not on spec |

---

## 13. What surprised me

1. ⭐ **The append-only automation law is weaker on disk than the tree believes, and stronger in a
   way nobody writes down.** Lanes persist NAMES; indices are derived per session. The real hazard is
   the silent `(0...N)` guard drop, not a corrupted save file (§3).
2. ⭐ **The elegant part of this design is free, not clever.** The side-path filter that applies the
   gain IS the band-isolated detector. One filter, two jobs, and `bandPassSection` already exists
   with the right normalisation for exactly the reason we need it.
3. ⛔ **The obvious shelf construction is broken** — `1 + (G−1)·LP` with a Butterworth low-pass
   boosts where it should cut. I would have shipped it if I had not swept the response.
4. ⛔ **The compressor's ballistics line does not generalise.** `targetDb < env` is correct only
   because its target is always ≤ 0. A signed-range dynamic EQ that copies it gets attack and release
   backwards on boost bands, and the one-sided rest-snap never lets a boost band return to unity.
5. ⚠️ **`m39-ae`'s "the audio path is untouched" framing does not transfer**, even though almost
   everything else about `m39-ae` does. Latency is still zero — for a different reason (§4.4). The
   NaN guard is the same guard with higher stakes.
6. ⚠️ **Two of the touch points the compiler cannot catch are the two that matter most to a user:**
   the "+" menu list (`MixerStripView.swift:8-14`, which says so itself) and the `default:` display
   name that would ship "DynamicEQ".

---

## 14. Open questions — offer, do not decide

None of these blocks the build. All three should be surfaced to the user rather than settled here.

1. **No gain-reduction meter in v1** (§9). Agents can see band movement via `fx_spectrum`; humans
   cannot. Would the user rather have one honest "deepest band moved by N dB" number than none?
2. **4 bands vs 3** (§10 G8). A pixel check decides it if nobody has a preference, but the user may.
3. **The `ratio` law in `below` mode** (§4.3) uses the compressor's slope rather than the textbook
   expander form. A dynamics specialist might want the latter. It is a musical call, not a
   correctness one, and the `audio-dsp-engineer` should be told it is open rather than discovering it.
