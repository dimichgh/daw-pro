# Errata to `2026-09-19-creative-effects.md`

**This file does not amend the frozen contract.** §6 and §7 of the creative-effects design are
normative and are edited only by an explicit amendment. Where an implementation reads against the
letter of a frozen line — or where the document contradicts itself — it is recorded here, **with the
measurement that forced it**, so the divergence is a stated decision rather than code that quietly
differs.

Every entry names: the frozen text, what shipped, the number that decided it, and who can overrule it.

**Entries, in the order they appear — which is priority order, not numeric order.** E4 sits third
because it is the only one that still **needs a ruling**; the rest are shipped decisions.

| | | |
|---|---|---|
| **E1** | the `1/sqrt(Q)` normalisation is applied RELATIVE TO the Butterworth Q | shipped |
| **E2** | the smoothing interpolates `position`, not the derived cutoff | shipped |
| **E4** | the brief and the frozen contract disagree about **which way the knob turns** | ✅ **RULED — reversed to match DJ hardware; §6.1.1 amended** |
| **E3** | the document assigns `m39-i` to two different items | reported |
| **E5** | §6.4.2 names an **integrated** band-limited triangle; PolyBLAMP shipped instead | shipped |
| **E6** | §9.3's 1.0 LU match cannot include a **no-effect control**; two shipped sets already break it | shipped, and it is a **doc** fix |
| **E7** | §6.2.3's "declared capacity: 0.100 s" describes a topology the FDN does not have | shipped |
| **E8** | §5.2's honest-`note` obligations are assigned to `m39-m`, which shipped without them | shipped under `m39-l` |
| **E9** | `.hallReverb`'s tank lines ship `.cubicHermite`, not the home's `.linear` default | shipped, on a measurement |
| **E10** | §6.2.2's `diffusion` is an allpass **coefficient**; driving it that way adds 35 ms of unaccounted pre-delay | shipped as a crossfade |
| **E11** | §3.1 says an echo freeze **needs ≈1.0** and that `highCutHz` is what bounds it; 1.0 diverges without bound and the filter is unity at DC | shipped at **0.999**, on a measurement |

---

## E1 — the `1/sqrt(Q)` normalisation is applied RELATIVE TO THE BUTTERWORTH Q

**Filed:** 2026-09-19, during `m39-i` (`.djFilter`). **Status:** shipped; overrulable by the
orchestrator or the user at any time — it is one line in `DJFilterEffect.deriveCoefficients`.

**The frozen text** (§6.1.3, *Output protection at high `resonance`*):

> A Q of 10 near self-oscillation can exceed the input by ~20 dB. **Frozen: apply `1 / sqrt(Q)`
> normalisation to the resonant section's output.**

**What shipped:** `sqrt(Q_butterworth / Q_eff)`, where `Q_butterworth = DJFilterParams.q(resonance: 0)
= 0.707`. This is the same law with its reference point named; it differs from the literal form by a
constant factor of `sqrt(0.707) = 0.841`, i.e. **−1.5 dB at every setting**.

**Why, and it is a measurement rather than a preference.** Taken literally, `1/sqrt(Q)` at
`resonance: 0` is `1/sqrt(0.707) = 1.19`, i.e. **+1.50 dB**. The consequences of that, both of which
contradict other frozen text in the same section:

1. **`resonance: 0` is specified as a clean Butterworth filter** ("0 = Butterworth (Q 0.707)",
   §6.1.2). A Butterworth filter that boosts its own passband by 1.5 dB is not one. A user setting
   resonance to zero to get "no character" would get a 1.5 dB lift on the whole band.
2. **§12 gate 9 demands `−3 dB at cutoffHz(atPosition:) ±2 %`.** Under the literal form the corner
   measures **−1.51 dB**, and the gate the same document specifies cannot pass. The two frozen
   statements are not simultaneously satisfiable.

**Measured, in `DJFilterTests` (L7a, L7b), printed by the suite on every run:**

| setting | passband gain, as shipped | under the literal form |
|---|---:|---:|
| `resonance: 0`, 12 dB/oct | **+0.0004 dB** | +1.50 dB |
| `resonance: 0`, 24 dB/oct | **+0.0007 dB** | +1.50 dB |
| `resonance: 1` (Q 10) | **−11.503 dB** (predicted −11.506) | −10.00 dB |

**What is NOT changed, and should not be read as softened.** The protection still costs passband
level at high Q — that is inherent to a single scalar gain and is not a defect of the reference
point. At `resonance: 1` the filter's passband is **11.5 dB down**. This is stated in the param's
own `fx.describe` note, in the MCP `fx_add` kind schema, and in the wire-reference skill, in each
case with the instruction *"that is the protection working, compensate with a gain insert if you need
the level back, do not read it as a bug"*. §6.1.3's other ruling — ⛔ **no limiter inside the
effect** — is followed exactly; nothing non-linear was added.

**If the orchestrator prefers the literal form**, the change is one line and `DJFilterTests` L7a will
redden at exactly +1.50 dB and L2 at −1.51 dB, which is what makes this entry falsifiable rather than
an opinion.

---

## E2 — the smoothing interpolates `position`, not the derived cutoff

**Filed:** 2026-09-19, during `m39-i`. **Status:** shipped. Arguably not a deviation at all — it is
the only reading under which the frozen behaviour is well-defined — but it is written down rather
than left implicit.

**The frozen text** (§6.1.3, *Coefficient smoothing is MANDATORY*):

> The effect keeps the **previous** quantum's derived cutoff, linearly interpolates toward the new one
> **per sample** across the quantum, and recomputes the SVF coefficient triple every **32 frames**.

**What shipped:** the **knob** (`position`, and likewise `resonance`, `deadZoneWidth`,
`resonanceTrack`) is what is held and interpolated; cutoff, filter MODE and the dead-zone wet gain are
**derived** from the interpolated position at each 32-frame boundary. The stride, the one-quantum lag
and the observable smoothness are exactly as frozen.

**Why.** Interpolating the *cutoff* is undefined across the centre, which is precisely where a DJ
filter spends its most characteristic moment. At `position = 0` there IS no cutoff (the law returns
`nil` — the effect is bypassed), and on either side the TOPOLOGY differs: a sweep from `−0.3` to
`+0.3` is a high-pass at 250 Hz handing over to a low-pass at 1.6 kHz. A linear interpolation of the
two cutoff NUMBERS would sweep 250 Hz → 1.6 kHz through whichever mode won the sign test, producing a
motion the user did not ask for. Interpolating the knob and re-deriving makes the centre crossing a
crossfade between two filters, which is what the dead zone exists to be.

**Pinned by:** `DJFilterTests` **L14a and L14b**, and by nothing else — which is worth stating
plainly, because an earlier revision of this entry claimed L1a/L1c/L9b pinned it and **that claim was
false**. Every other leg in the suite renders with a static param set or a *constant* automated
value, so all 25 of them stay green against a build with the interpolation deleted outright
(`previousPosition = targetPosition` written at the top of `process`). That was verified by planting
exactly that deletion: 25 legs green, **L14a and L14b the only two that reddened.**

- **L14a** holds slot 0 at 0.3 for eight quanta and steps it to 0.6. The first 32 frames of the
  post-step quantum must be **byte-identical** to a held-at-0.3 render — the interpolation's `t = 0`
  point *is* the previous quantum's knob — and the last 32 must match **neither** control. Under the
  deletion the first stride diverges at frame 0. The step is then shown to be *bounded*: six quanta
  later the render is within **4.1e-7** of the held-at-0.6 target.
- **L14b** sweeps slot 0 from 0 to 0.8 across 40 quanta at 512- and at 256-frame block sizes. The two
  renders differ by **0.49** on a 0.6-amplitude input — §6.1.3's admitted block-size dependence,
  quantified, and much larger than one might guess because a one-quantum position lag of 0.01 moves a
  three-decade log cutoff by 7 %, which is most of a Q-4.4 peak's own width. The pinnable fact is that
  the divergence is a **pure lag**: advancing the 512-frame lane by one 256-frame quantum of sweep
  makes the two renders agree to **exactly 0.0** over the remaining 19 456 frames. Under the deletion
  that same compensation leaves **0.45** — a staircase cannot be shifted onto a different staircase.

The 32-frame stride is named in `DJFilterEffect.coefficientStride`.

---

## E4 — the BRIEF and the FROZEN CONTRACT disagree about which way the knob turns

**Filed:** 2026-09-19, during `m39-i`. **Status:** ⚠️ **NEEDS A RULING.** Shipped following the
FROZEN contract; reversing it is a one-line change plus two test edits and two demo renames.

| source | negative `position` | positive `position` |
|---|---|---|
| **§6.1.1, frozen** — and `DJFilterParams.cutoffHz(atPosition:)`, which is written to match | **HIGH-pass, corner rising 20 Hz → 20 kHz** (bass leaves) | **LOW-pass, corner falling 20 kHz → 20 Hz** (treble leaves) |
| the `m39-i` task brief as written | low-pass sweeping down | high-pass sweeping up |

**What shipped follows §6.1.1**, on the rule that §6 is normative and a brief is not an amendment.
Everything downstream is consistent with it: `DJFilterTests` **L4** exists for no other purpose than
to pin the direction (every other response leg is symmetric in the two modes and would stay green
through a sign flip), the `fx_add` kind schema and the wire-reference skill both state the direction
in words, and the rendered demo confirms it — at the sweep extreme `sweep-down-lp` (positive) has
collapsed the **high** band to −76.5 dB while `sweep-up-hp` (negative) has collapsed the **low** band
to −91.0 dB.

⚠️ **The audible consequence of not ruling on this:** a listener opening
`scripts/demos/specs/djfilter.json`'s output expecting the brief's convention will hear each variant
do the opposite of what its *name* leads them to expect, and conclude the filter is broken when it is
behaving exactly as specified.

**To reverse it:** flip the `p < 0` branch in `DJFilterParams.cutoffHz(atPosition:)` and the matching
`isHighPass(atPosition:)`; `DJFilterTests` L0 and L4 then redden and are the two edits; and the demo
variant names `sweep-down-lp` / `sweep-up-hp` swap. The DSP itself is direction-agnostic — it reads
the law — so no render-path code changes.

### ✅ RULED 2026-09-19 — REVERSE IT. Negative = LOW-pass, positive = HIGH-pass.

**§6.1.1 is amended, and this erratum is the amendment.** Raising it rather than silently following
the brief was the right call; the ruling goes the other way on evidence the frozen text does not
contain.

**The evidence.** This effect's own doc comment calls it "the club-mixer / DJ-mixer sweep" — it is
defined by the hardware it imitates. On that hardware the direction is not a preference:
Pioneer's centre-detented filter/COLOR knob gives **low-pass to the LEFT and high-pass to the
RIGHT**, and the convention is consistent across the DJM line. §6.1.1 specified the opposite, and
carried **no rationale for the choice** — there is no argument in the document to weigh against
this, only an assertion. ⭐ **An effect whose entire identity is imitating a hardware control, that
inverts that control's direction, is wrong by its own definition.**

**Why now and not later — this is a ONE-WAY DOOR.** `position` is persisted in project files and is
automation slot 0. The moment one project is saved with a non-zero `position`, or one automation
lane is drawn on slot 0, reversing the sign stops being four edits and becomes a data migration that
silently re-voices every existing project. Today the cost is: two branches, two test legs, two demo
variant names. **The window closes on first use, so the cheap moment is the only moment.**

**Against reversing** (stated so the decision is falsifiable, not just asserted): "negative =
high-pass" reads naturally as "negative removes the low end", and the shipped code, tests, MCP
schema and skill text are all self-consistent today. That consistency is real — and it is exactly
what makes the change cheap *now* and expensive later. Internal consistency with a convention users
do not share is not a reason to keep it.

⚠️ **The teaching text has to move with the sign, in all three homes** (`Effects.swift`,
`server.ts`, `SKILL.md`) — the agent already rephrased them from "going down"/"going up" to
"for a NEGATIVE position …", so the wording is now sign-anchored and MUST be re-checked, not
assumed to survive. A stale sentence here is worse than none: it teaches an agent the wrong
direction with authority.

---

## E3 — the document assigns `m39-i` to TWO different items

**Filed:** 2026-09-19, during `m39-i`. **Status:** reported, not resolved here — item IDs are the
orchestrator's, and §11.0.2 says so explicitly (*"`docs/ROADMAP.md` is the orchestrator's file. This
document does not touch it"*).

The design document contradicts itself about what `m39-i` is:

| location | what it says `m39-i` is |
|---|---|
| **§11.0.2 table (line 1441)** | **the DJ filter** |
| `docs/ROADMAP.md:3778` | **`.djFilter` — BUILD FIRST** |
| §3.1 (line 166) | the ducked-reverb preset + warning |
| §11.1 Leg 0 table (line 1467) | the ducked-reverb preset + warning |

§11.0.2 is the section that *settles* the IDs ("The IDs below are final and the document uses them
throughout"), and `docs/ROADMAP.md` — the file that actually governs — agrees with it. §3.1 and
§11.1 carry the pre-rename allocation, where the Leg 0 documentation items held `i`/`j`/`k`/`m`.
**The DJ filter was built as `m39-i` on that basis.** The Leg 0 items (ducked-reverb preset, the
honest filter-sweep paragraph, the reverb note, the echo-freeze range) still need IDs that are not
`m39-i`/`m39-j`/`m39-m`, and that is a filing decision for whoever owns the roadmap.

---

## E5 — the band-limited TRIANGLE is a PolyBLAMP, not an integrated square

**Filed:** 2026-09-19, during `m39-m` (`.ringMod`). **Status:** shipped; overrulable by the
orchestrator or the user at any time — it is one branch in `RingModEffect.carrier`.

**The frozen text** (§6.4.2, part 1, *The carrier's own harmonics must be band-limited*):

> **Frozen: `waveform` 1–3 are generated band-limited** (PolyBLEP for saw and square, **an
> integrated band-limited triangle**).

**What shipped:** saw and square are PolyBLEP exactly as frozen. The triangle is a **PolyBLAMP** —
the naive triangle `1 − 4·|p − 0.5|` plus `8·dt · (blamp(p) − blamp(p + 0.5))`, where
`blamp(τ) = (1 − |τ|)³ / 6` is the integral of the same residual PolyBLEP uses. It is the same
*family* of correction applied to the same *contract*; what it is not is an integration.

**Why, and it is a property rather than a preference.** "Integrated" names a specific construction:
generate a PolyBLEP square and run it through a leaky integrator, `tri += 4·dt·sq`. That construction
has a state variable, and the state is the problem:

1. **The leak is sized against the carrier, and the carrier spans 13 octaves.** `carrierHz` runs
   **0.5 … 5 000**. A leak slow enough not to distort a 0.5 Hz triangle (one cycle is 96 000 samples)
   is far too slow to stop the integrator drifting; a leak fast enough to hold DC at 5 kHz flattens
   the 0.5 Hz one into something that is no longer a triangle. There is no single coefficient that
   serves both ends of a range this wide.
2. **`carrierHz` is `modulatable: yes`, so `dt` CHANGES WHILE THE INTEGRATOR IS RUNNING.** The
   integrator's output amplitude is set by `4·dt` accumulated over half a cycle; move `dt` mid-cycle
   and the amplitude wobbles, which on a carrier is an amplitude modulation of everything the effect
   is multiplying. PolyBLAMP is **stateless** — it is a function of `(phase, dt)` and nothing else —
   so a carrier sweep changes the shape's frequency and leaves its amplitude alone. §6.4.1 grants
   `carrierHz` a `yes` verdict specifically because a carrier change is safe; an integrator would
   have made that verdict harder to keep.

**Measured, in `RingModTests` L4c, printed by the suite on every run.** Worst alias in the
**audible band** (below 16 kHz) at a 2 917 Hz carrier, relative to the carrier's own fundamental:

| triangle generator | worst audible alias |
|---|---:|
| naive (no correction) | **−41.66 dB** |
| **PolyBLAMP, as shipped** | **−57.00 dB** |

The naive figure is not an estimate: it was obtained by **planting** the naive generator in
`RingModEffect.carrier` and running the suite, which reddened **L4a, L4b and L4c and nothing else**
— 3 legs of 32. L4c's threshold of −48 dB sits 6.3 dB above the naive number and 9.0 dB below the
shipped one.

**What is NOT claimed.** PolyBLAMP is not more accurate than a correctly-tuned integrator would be
at a *fixed* carrier; the argument is that a fixed carrier is not what this parameter is. And the
2-point kernel was kept over the 4-point one deliberately: measured, the 4-point cubic-B-spline
kernel reaches **−51.5 dB** on the saw where the 2-point reaches −36.2, but it does so partly by
eating the *legitimate* harmonics as well (harmonic 8 of a 2 917 Hz saw drops to −32.6 dB against an
ideal −18.1, versus −25.3 for the 2-point) and it drags the saw's peak amplitude down to **0.72** at
a 5 kHz carrier, so switching `waveform` would become a level change rather than a timbre change.
§6.4.2 froze "PolyBLEP", which is the 2-point kernel by default, and the measured audible-band
improvement over naive is already **15–19 dB**.

**If the orchestrator prefers the integrated form**, the change is one branch of
`RingModEffect.carrier`; `RingModTests` **L4c** is the leg that would move, and **L4e** (every
waveform peaks at ±1) is the one that would catch a leak coefficient sized wrong.

---

## E6 — §9.3's 1.0 LU loudness match CANNOT include a no-effect CONTROL variant

**Filed:** 2026-09-19, during `m39-m` (`.ringMod`). **Status:** shipped as a deviation; this one is a
**documentation** fix rather than a code decision, and it is **already the de-facto rule** — two
sets that shipped before this item break the line as written.

**The frozen text** (§9.3):

> ⛔ **Frozen: every variant in a set is loudness-matched to within 1.0 LU of the set's median
> integrated loudness, and the manifest records each variant's measured value.**

**Why it exists, and that reason is right:** §9.3's own paragraph says it — the audibility guard
catches *byte-identical* variants but not four variants that differ only in **level**, which a
listener reliably reports as "the third one" for the wrong reason. On an axis like `resonance` or
`mix` that is exactly the trap.

**What it cannot cover is a `role: "control"` variant**, because a control is by construction the
sound with the effect *absent*, and most wet effects change the level. Normalising the control would
not remove a confound, it would **manufacture** one: the listener would be unable to tell that the
effect changed the level at all, which for a mix-bearing effect is part of what they have to judge.

**Measured, from the rendered manifests of sets already in `scripts/demos/out/` — this is not a
prediction:**

| set | item | variants (integrated LUFS) | control's offset from the set median |
|---|---|---|---:|
| `dj-filter-sweep` | m39-i | −21.9 · −22.1 · −22.3 · −22.5 | **+0.3 LU** — compliant, and it is the set where the rule bites |
| `djfilter` | m39-i | **−15.3** (control) · −20.9 · −21.4 · −23.2 | **+5.85 LU** |
| `mod-tremolo` | m39-e | −19.6 (control) · −19.3 · −17.6 · **−15.3** | spread **4.3 LU**; `depth` moves loudness by definition |
| `ringmod` | m39-m | **−19.6** (control) · −23.8 · −23.9 · −23.7 | **+4.2 LU** |

`ringmod`'s three **on-axis** variants sit within **0.2 LU** of each other — the axis is
`carrierHz`, and carrier frequency does not change how much energy the multiply passes, so the rule's
actual purpose is satisfied exactly. The +4.2 LU is arithmetic, not a mix decision: at `mix: 0.5`
half the output is `x · sin`, and a sine's RMS is 0.707, so the wet half is quieter than the dry half
it replaced.

**What shipped instead:** the rule applied to the **on-axis** variants, and the control's offset
**stated and explained in the listening note**, so it cannot be mistaken for the axis —
`scripts/demos/specs/ringmod.json` carries a paragraph headed *"LOUDNESS, STATED SO IT IS NOT MISTAKEN
FOR THE AXIS"* that gives the number, the cause, and the instruction ("do not pick the control because
it is louder; it is there to tell you what was taken away").

**Proposed amendment to §9.3, for whoever holds the pen:** *every variant on the axis is
loudness-matched to within 1.0 LU of the median of the on-axis variants; a `role: "control"` variant
is exempt, and its measured offset is stated in the listening note with its cause.* That is what
three of the four shipped sets already do.

**Who can overrule:** the orchestrator or the user. The alternative is a per-variant output trim in
the demo spec, which is buildable — but it would make the control a processed signal, and the note
would then have to explain the trim instead of the effect.

---

## E7 — §6.2.3's "declared capacity: 0.100 s" describes a topology the FDN does not have

**Filed:** 2026-09-19, during `m39-l` (`.hallReverb`). **Status:** shipped.

**The frozen text** (§6.2.3, *DSP — frozen shape*):

> **Tail modulation through `InterpolatedDelayLine`** (§4.1), one independent LFO phase per line.
> **Declared capacity: 0.100 s** (max `modDepthMs` plus interpolation margin), **separate from the
> line storage itself.**

**What that phrasing imagines** is a two-part line: a bulk integer delay carrying the line's length,
plus a short *separate* `InterpolatedDelayLine` carrying only the modulation excursion. Under that
split, 0.100 s is the right size for the short part.

**What shipped:** each of the eight tank lines **is** one `InterpolatedDelayLine`, and the modulation
is added to its tap. There is no second structure, so **0.100 s has no referent** — the number cannot
be honoured because the thing it sizes does not exist.

**Why the one-line form, and not the split the text imagines.** The split buys nothing and costs the
thing the parameter exists for. `sizeMeters` has to move **smoothly** (§5.5 promises a Doppler glide,
not a step), which means the line's length is a *fractional* number of samples that changes every
sample — so the bulk part cannot be an integer delay. Two interpolated reads per line per sample to
express one delay is strictly worse than one.

**What the capacity actually is**, and it is derived rather than written down:

```
lineCapacitySeconds = sizeRange.upperBound / 343 × max(lineLengthRatios) + modDepthRange.upperBound/1000
                    = 60 / 343 × 1.4333 + 0.005
                    = 0.2557 s
```

— the longest line at the largest room, plus the largest upward modulation excursion; the exact
value is **0.255 728 862 973 760 9 s**. **Allocation per instance at 48 kHz, computed from that
number rather than estimated:** 8 tank lines × `ceil(0.2557… × 48 000) + 4` = 8 × 12 279 =
**98 232 floats**, plus a 0.260 s mono pre-delay line (**12 484**) and four fixed diffusers
(**1 701**) = **112 417 floats = 449 668 bytes ≈ 439 KiB per insert**, all of it taken once in
`prepare()` and never resized.

⭐ **The D4 plate-budget comparison, with the two sides labelled differently ON PURPOSE.** §5.3 asks
for the number whenever someone measures it, so: **MEASURED, by me, on the shipped effect** — this FDN
reserves **2.0458 s** of tank storage per insert (8 × `lineCapacitySeconds` 0.2557), i.e. the 98 232
tank floats above. ⚠️ **NOT MEASURED, and it must not be read as if it were** — the plate side. A
Dattorro tank is nominally a few hundred milliseconds across its two loops, which is the *design's own
prior* (§5.3) restated, not a figure produced in this item: **no plate is built here**, so there is
nothing to measure yet. The honest conclusion is therefore conditional, not a verdict: **if the plate
comes in anywhere near its published size it fits inside the existing reservation with room to spare,
and `topology` is a mode rather than a kind** — decided at plate-build time against the plate that is
actually written.

**Who can overrule:** the orchestrator or the user. The fix if overruled is not small — it is a
different line topology — which is why the number is recorded here rather than quietly ignored.

---

## E8 — §5.2's honest-`note` obligations are assigned to `m39-m`, which shipped without them

**Filed:** 2026-09-19, during `m39-l`. **Status:** shipped, under `m39-l`.

**The frozen text** (§5.2): *"Frozen text obligations for `m39-m`:"* — followed by the two honest
notes that must land on `reverb.roomSize` and on the `.reverb` kind description.

**Why that is an error and not a reading of mine:** `m39-m` is `.ringMod` (§6.4). The obligations are
about `.reverb` and they exist *because* `.hallReverb` arrives, which is `m39-l`. **Verified against
the shipped tree:** `m39-m` landed and `EffectParamSpec.specs(for: .reverb)` carried **no `note` on
any of its five entries** — the obligation was assigned to an item that had no reason to notice it,
and it was duly missed.

**What shipped:** both notes, under `m39-l`, on **both** surfaces §5.2 names —
`EffectParamSpec.specs(for: .reverb)` and the MCP tool text (`fxKindSchema` and `fx_describe`) —
because an agent reading one and an agent reading the other must not disagree. Additive metadata
only: no name, range, default or **position** moved, so **no automation slot moved and no saved
project changed.**

⚠️ **The `.reverb` kind is NOT deprecated in prose**, and `mcp-server/test/fx-hall-reverb.test.ts`
pins the ABSENCE of the word — the only kind of assertion that can catch a well-meaning future edit
adding it.

**Who can overrule:** nobody needs to; this is a filing correction. Recorded so the next reader of
§5.2 does not go looking for the work in `m39-m`'s close record.

---

## E9 — the tank lines ship `.cubicHermite`, not the home's `.linear` default

**Filed:** 2026-09-19, during `m39-l`. **Status:** shipped, **on a measurement**.

**The frozen text** (§4.1, the *interpolation* row): safe default **`.linear`** — *"it is what ships
today, it is what the byte-identical chorus gate pins, and it is correct for every modulation depth
in the musical band. `cubicHermite` exists for the tape delay … An implementer must not switch an
existing caller to `cubicHermite` to 'improve' it."*

**That rule is about EXISTING callers and it is obeyed exactly:** the chorus and the flanger are
untouched, and the chorus-migration byte gate is **green with all three hashes unchanged** (positive
control: `baseline` vs `control-perturbed` still differ by **2 619 028 bytes**). A **new** caller
chooses, and §4.1 describes this caller's situation by name — *"a slow deep wow sweeps the fractional
tap continuously and linear interpolation's frequency-dependent loss becomes an audibly dull top
end."*

**An FDN is that case compounded.** A chorus passes its line **once**; each tank line is re-read
roughly **fifty times per second**, so the interpolator's per-pass loss is raised to the fiftieth
power every second. **Measured at 48 kHz, `decaySeconds: 4`, absorption neutral:**

| | `.linear` | `.cubicHermite` |
|---|---|---|
| broadband RT60 / requested, at 1 / 2 / 4 s | 0.90 · 0.85 · **0.775** — it gets WORSE the longer you ask for | **0.90 · 0.90 · 0.90** — constant |
| RT60 at 8 kHz, asking for 4 s | **2.23 s** | **4.70 s** |
| `highDecayMultiplier` 1.0 → 0.1, 8 kHz against 1 kHz in the 1–2 s tail | −37.2 → −66.8 dB | −20.0 → −64.9 dB |

With `.linear` the kind **could not meet §12 gate 9's "RT60 within 10 % of `decaySeconds`" at all**,
and `highDecayMultiplier: 1` — documented as *"no damping at all, bright"* — was a **lie**: the
interpolator had already removed the top end before the parameter got a vote. (Schroeder-integration
RT60 with `.cubicHermite`, measured across the range: ratio **0.905–0.992**.)

⚠️ **Stability was checked rather than assumed**, because Hermite is not a passive interpolator and
this loop reaches **unity gain** at `freeze`. Worst case measured (`freeze: 1`, `sizeMeters: 1` — the
shortest lines, hence the most recirculations per second any setting can produce): **+0.005 dB over
17 seconds**. Unfrozen worst case (`decaySeconds: 20`, `sizeMeters: 1`, `lowDecayMultiplier: 4`):
**−22.4 dB over 27 s**, every sample finite. Pinned by `HallReverbTests` H8.

⛔ **The PRE-DELAY line stays `.linear`, and it has no choice**: `.cubicHermite`'s floor is **2**
samples (§4.1's own addendum — its stencil reads one sample *newer* than the tap) and that line
declares a floor of **1**. The tank's floor is the shortest line at `sizeMeters: 1` — **72.9 samples
at 44.1 kHz, 79.3 at 48 kHz** — so Hermite's 2 is met with three orders of magnitude to spare.

**Who can overrule:** the orchestrator or the user. It is one enum value in `HallReverbEffect`, and
reverting it costs the RT60 gate.

---

## E10 — `diffusion` is an equal-power CROSSFADE, not the allpass coefficient

**Filed:** 2026-09-19, during `m39-l`. **Status:** shipped, on a measurement.

**The frozen text** (§6.2.2, slot 5): *"`diffusion` — input allpass density"*; §6.2.3 says only
*"per-line absorption"* about the tank and leaves the diffuser's wiring open.

**What the obvious reading produces, and it is wrong.** Driving the Schroeder allpass **coefficient**
with `diffusion` looks right and fails at one end: an allpass at `g == 0` is a **pure delay**. So
`diffusion: 0` — which the parameter's own note promises means *"a drum hit enters the tank as a drum
hit"* — instead delayed the entire input by the diffusers' serial length. **MEASURED: 1 701 samples
at 48 kHz**, which put the first wet arrival at **56.6 ms** when the closed form says **19.8 ms**. A
knob nobody turned was adding **35 ms of pre-delay that no parameter accounted for**, and the
direction was backwards too: *less* diffusion made the effect *later*.

**What shipped:** the allpass coefficient is fixed at **0.7** (the value at which a Schroeder diffuser
still reads as scatter rather than as a resonance) and `diffusion` is an **equal-power crossfade**
between the direct pre-delayed signal and the scattered one. `diffusion: 0` is now exactly what the
note says it is, and the first arrival matches the closed form to **within one sample at every size**
(measured 951 / 1903 / 3806 samples at 12 / 24 / 48 m against a closed form of 951.6 / 1903.2 /
3806.4). Equal power rather than linear because the direct and scattered paths are decorrelated — a
linear blend would dip ~3 dB in the middle of the knob.

**Who can overrule:** the orchestrator or the user. Pinned by `HallReverbTests` H2b and H5a, which
compare the measured first arrival against `HallReverbParams.firstArrivalSeconds`.

---

## E11 — the echo freeze ships at `0...0.999`, and `highCutHz` is not what bounds it

**Filed:** 2026-09-19, during `m39-k`. **Status:** shipped, **on a measurement**, in two parts.

**The frozen text** (§3.1, *"Echo freeze is NOT already possible"*): *"A freeze/echo-out needs
feedback at or fractionally above **1.0** so the repeats sustain instead of decaying"*, and *"a
feedback of exactly 1.0 with a self-keyed filtered loop is a **marginally stable** structure — the
existing `highCutHz` in the feedback path is what keeps it from ringing forever"*. §11's Leg 0 table
turns that into *"widen `DelayParams.feedbackRange` to `0...1.0`"*.

### Part 1 — 1.0 is not marginally stable, it diverges, and the number says so

`DelayEffect`'s loop is `line[w] = dry + lowpass(line[r]) · feedback` with an INTEGER tap (no
interpolation gain) and a one-pole low-pass whose magnitude peaks at **exactly 1 at DC** and is below
1 everywhere else. The loop gain at DC is therefore `feedback` outright, and at `feedback == 1.0` the
structure is an integrator at DC: a tail does not grow, but **any sustained input the loop cannot
lose accumulates linearly and for ever**.

**Measured** (10 ms delay, `mix: 1`, constant 0.1 input, peak per 10 s window), at **both** ends of
the `highCutHz` range, because the filter is where the frozen text located the safety:

| feedback | `highCutHz` | t = 10 s | 20 s | 30 s | 40 s | converges? |
|---|---|---|---|---|---|---|
| **1.0** | 500 (most damped) | 96.97 | 193.94 | 290.94 | 388.02 | **no — increments constant to three figures** |
| **1.0** | 20 000 | 99.90 | 199.90 | 299.91 | 399.90 | **no — step 100.00, i.e. exactly 0.1 × 100 repeats/s × 10 s** |
| **0.999** | 500 | 62.10 | 85.64 | 94.56 | 97.95 | yes, onto 1/(1−f)·0.1 = **100** |
| **0.999** | 20 000 | 63.19 | 86.47 | 95.02 | 98.17 | yes, onto the same **100** |

⭐ **The two `highCutHz` rows are the argument, not decoration.** At 1.0 the most damped setting
available buys 3 % off the growth rate and nothing else; at 0.999 the two settings land within 1 % of
the same ceiling. The filter does not participate in the bound in either direction.

A 1 kHz tone driving a comb peak behaves the same way: bounded at 24.0 at 0.999. **0.999 is
therefore the largest value that still cannot run away** — and it is a freeze by any musical
measure: 0.0087 dB lost per repeat, a 350 ms tail **3.19 dB down after 110 seconds** (peak
0.8876 → 0.6149 over a two-minute render), against 0.45 dB per repeat at the old 0.95 ceiling.

⚠️ **Direction matters here more than the value.** Widening a range later is backward-compatible;
narrowing it silently re-voices every project saved at the old maximum. `0...1.0` would have been a
one-way door onto an unbounded structure, and the cheapest moment to not walk through it is before
the first project is saved at 1.0.

### Part 2 — `highCutHz` supplies no stability margin; it sets how long the hold lasts

The second half of the frozen sentence is the load-bearing one and it is **false**: the divergence
above was measured at `highCutHz` **500**, the most damped setting the range allows. A one-pole
low-pass is unity at DC at every corner frequency, so it cannot bound a unity-feedback loop at all.

What it *does* do at a freeze-grade feedback is decide the hold's length. **Measured**, 350 ms delay,
feedback 0.999, burst then silence:

| `highCutHz` | broadband **peak** decay | **220 Hz component** decay | tail peak, 0–10 s → 30–40 s |
|---|---|---|---|
| 20 000 | **0.029 dB/s** — 3.19 dB down after 110 s | 0.013 dB/s | 0.8876 → 0.8038 |
| 500 | **0.845 dB/s** — gone in about 20 s | 2.201 dB/s | 0.7801 → 0.0422 |

⚠️ **The two decay columns differ by 2×, and that is real, not a discrepancy**: the loop's low-pass
damps the burst's 660 Hz component harder than its 220 Hz one, so the broadband peak falls faster
than the 220 Hz partial does. **Always say which measure a decay number is.** The peak column is the
one quoted in the `highCutHz` param note (it is the conservative one); the component column is what
leg **L5** asserts on. Every figure in this table is printed by `EchoFreezeTests` L2 and L5 on each
run — `rtk proxy grep '\[measured\] 350 ms tail' <test log>` reproduces them.

Both numbers are now in the parameters' own `note`s, and the `feedback` note additionally states the
build-up hazard the ceiling implies (sustained input tends to 1/(1−feedback) times itself, over
`timeMs`/(1−feedback) seconds) together with the way to avoid it: **put the delay on a bus and pull
the send to 0**, which is the input-mute a hardware freeze button provides.

### Part 3 — no discrete `freeze` parameter, and the measurement is the reason

A boolean `freeze` would duplicate "feedback at its maximum" (measured −0.0175 dB/s on the 220 Hz
component, −0.029 dB/s broadband peak, at the ceiling, 350 ms, `highCutHz` wide open) while permanently spending a positional automation slot, which §6.0 makes append-only for
ever. The one thing a hardware freeze adds — muting the loop's input — is already reachable through
sends, so the continuous knob plus a note is the whole feature.

**Byte-identity, because this is a range change on a shipped effect with existing users:** a
four-variant demo set (`scripts/demos/specs/echofreeze.json`) was rendered on the pre-change build
and again after. `no-echo`, `feedback-40` and `feedback-95` hash identically across the change;
`freeze-999`, which clamped to 0.95 before it, hashes differently — the positive control proving the
comparison could have caught something. A pre-change FNV-1a pin over a feedback-0.95 render is kept
in `EchoFreezeTests` L8 as the permanent guard.

**Who can overrule:** the orchestrator or the user. It is one constant
(`DelayParams.feedbackRange`), but **raising it to 1.0 is the one direction the measurement forbids**
and lowering it re-voices saved projects.
