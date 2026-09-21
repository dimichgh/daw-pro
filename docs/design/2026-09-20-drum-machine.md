# Design — The Drum Machine (`.drumSynth`), an 808/909-lineage synthesised kit

**Item:** m39-dm · **Wave:** (2) in the user's ruled order of 2026-09-19 — effects suite →
**our own drum machine** → multi-instrument templates → loop/drum depth.
**Author:** daw-architect · **Date:** 2026-09-20 · **Status:** design only, no code written.
**Brief (user's words):** *"an 808/909-style synthesised kit as a NEW instrument kind, every
parameter MCP-exposed and automatable."*

Every claim about this codebase below cites `file:line` that was read. Anything not verified is
marked **UNVERIFIED** rather than asserted. Nothing was built or run — two other agents held the
tree during this pass.

---

## 0. The decision, in one page

Ship a **sixth `InstrumentDescriptor.Kind`, `.drumSynth`**, carrying an additive-optional
`drumKit: DrumKitParams?` payload beside `polySynth` / `sampler` / `audioUnit` / `soundBank`
(`Sources/DAWCore/Model.swift:1647-1682`).

It is **eight fixed, named, monophonic one-shot voices** — `kick`, `snare`, `closedHat`,
`openHat`, `clap`, `tom`, `rim`, `cymbal` — each a hand-written synthesis topology, not a generic
engine with a mode switch. Voices are struct **fields with names**, never an array with indices.

Parameters are addressed by **dotted name, `<scope>.<param>`** (`kick.tune`, `openHat.decay`,
`kit.accentDepth`) through the **existing** `AutomationTarget.instrumentParam(paramName: String)`
case (`Sources/DAWCore/Automation.swift:40`). No new automation case, no new coding key, no new
wire shape, no positional index anywhere.

**75 addressable parameter names. Zero discrete parameters.** This is the first instrument in
DAW Pro where `InstrumentParamSpec.discreteParamNames(for:)` returns `[]` and *every single name*
is modulatable — which is precisely what the user asked for.

### The three things that decide the design

1. **`Sources/DAWCore/InstrumentParams.swift:18-24` forbids positional addressing for instrument
   parameters, in those words.** The effect side's slot index *is* the array position and is
   append-only forever (`Sources/DAWCore/Effects.swift:4218-4223`). The instrument side is
   deliberately the opposite: *"Instrument params are addressed **by name** end to end … So these
   arrays may be reordered freely, and **must not** acquire an index-addressed setter later. This
   is the single most likely future mistake in this file."* A drum machine is the first thing that
   will tempt someone to break it (a `pads: [DrumVoiceParams]` array is an index). We do not.
2. **A drum voice's parameters are consumed at note-on and nowhere else.** That is what a one-shot
   is. It makes the whole render-path question trivial and is why this instrument needs none of
   PolySynth's 32-frame modulation re-derivation stride
   (`Sources/DAWEngine/Instruments/PolySynthInstrument.swift:238-251`).
3. **Instrument-parameter *automation lanes* are refused engine-wide today** — see §3.6. The brief's
   word "automatable" is met on day one through `mod.addRoute`, not through hand-drawn lanes, and
   the design must say so out loud rather than imply otherwise.

---

## 1. Why synthesise rather than ship sampled kits

The obvious alternative: we already have a sampler, so bundle 8 WAVs per kit and ship five kits.

**Measured, not assumed:** `Sources/DAWCore/BundledSamples.swift:78-93` — the entire bundled-sample
catalog is **one entry**, `test-tone-a4`, a 0.35 s A4 one-shot. There is **no** drum content in the
repo. The "just use the sampler" path is not a shortcut; it is an asset-acquisition, licensing,
repo-size and per-kit-authoring project that produces no new capability.

Five reasons synthesis wins here, in order of weight:

1. **A sample has no parameters.** The user's goal is *"every parameter MCP-exposed and
   automatable."* A sampled 808 kick exposes `tune`, `level`, `pan` and a start offset. A
   synthesised one exposes its pitch envelope, its body decay, its click, its drive — ten
   continuous axes an agent can reason about in words ("longer boom, harder click") and automate
   per bar. Sampling converts the entire premise of the item into a gain knob.
2. **We would be shipping a worse version of what we already have.** A sampled kit is a
   `SamplerParams` with eight zones. It needs no new instrument kind, so it is not item (2) of the
   wave order at all — it is content for item (3), multi-instrument templates.
3. **Repo and licensing cost.** Every bundled sample is bytes in the product and a provenance
   question. Synthesis costs ~1200 lines of Swift and zero bytes of content.
4. **The research already ranked it first and said why.**
   `docs/research/2026-09-19-synthesis-engines.md:412-418` ranks `.drumSynth` as *"Highest
   payoff-to-complexity ratio on the entire"* list, and :370 classes it **Low** complexity with
   **PARAM**-only control: *"one-shot voices, no sustain/pedal/voice-stealing logic to interact
   with."* :543 — *"this instrument needs no MODULATOR-class work at all, which is exactly why it
   is ranked first."*
5. **The one place sampling genuinely wins is already covered.** The TR-909's hi-hats, ride and
   crash are **6-bit PCM samples**, not analogue circuits — the 909 team ran out of schedule trying
   to synthesise cymbals and went digital for those voices alone
   ([Attack Magazine, Atsushi Hoshiai interview](https://www.attackmagazine.com/features/interview/atsushi-hoshiai-the-man-behind-the-tr-909/)).
   So "a 909 hat" is, historically and literally, a sample — and a sample is what our sampler is
   for. Our synthesised hat follows the **808** lineage, which is the one that is actually a
   circuit. §2.4 states this rather than pretending otherwise.

**Rejected.** Sampled kits are not declined, they are *re-filed*: they belong to wave item (3)
(templates/content) and they compose with this instrument rather than competing with it.

---

## 2. Voice architecture — the actual synthesis

### 2.0 Shared primitives, and the two that are non-obvious

**The exponential envelope, defined by its own assertion.** Every decay in this instrument is a
one-pole exponential whose parameter *is* the −60 dB time. Given a decay parameter `T` seconds:

```
c = pow(10, -3 / (T * fs))            // derived ONCE per note-on, never per sample
e[0] = 1
e[n] = e[n-1] * c                     // one multiply per sample
```

At `n = T·fs`, `e = 10⁻³` = −60 dB **exactly**. This is deliberate: it makes the parameter's
contract and the verification assertion the same statement, so §8's decay tests check the
*published meaning* of the knob rather than an implementation detail.

**A 2-pole modal resonator instead of `sin()` for fixed-pitch partials.** For any partial whose
frequency does *not* sweep (snare tone, tom overtone, rim), use the decaying-sinusoid recursion:

```
ω = 2π f / fs ;  R = pow(10, -3/(T*fs))
a1 = 2 R cos(ω) ;  a2 = R²
y[n] = a1·y[n-1] − a2·y[n-2]          // 2 mul + 1 sub per sample, no transcendentals
init: y[-1] = 0, y[-2] = −sin(ω)/R    // unit-amplitude impulse response start
```

`a1`/`a2` are derived at note-on (two `cos`, one `pow`) and frozen for the life of the hit. This is
the "modal synthesis" upgrade path `docs/research/2026-09-19-synthesis-engines.md:156-159, 278-280`
names, taken in v1 for free because a one-shot never needs to change its coefficients mid-note.

**Noise: xorshift32, seeded from the note-on position.** ⚠️ **This is the one RT detail a naive
implementation gets wrong and no unit test catches.** A free-running PRNG makes the render a
function of *how many notes came before*, which breaks the project's position-absolute determinism
law — the same law `ModulationSnapshot.swift:27-33` exists to protect ("every source here is a
function of the PROJECT-ABSOLUTE position … or an LFO would restart its phase at every play press
and the position-absolute determinism law (§3.2) would be false in exactly the case it exists to
guarantee"). Rendering from bar 5 would then not match bar 5 of a full render.

**Therefore: seed per note-on, from the note's absolute sample position and the voice index.**

```
seed = splitmix32( UInt32(truncatingIfNeeded: noteOnSample) ^ (UInt32(voiceIndex) &* 0x9E3779B9) )
```

One multiply and a few shifts, at note-on only. Result: each hit varies (analogue-like), the whole
render is a pure function of position (suffix-identity holds), and `reset()` needs to clear nothing.

**Drive.** Reuse the antiderivative-antialiased `tanh` already in the tree,
`Sources/DAWEngine/Instruments/PolySynthInstrument.swift:830` (`adaaTanh`) — including its warning
at :117-124 that the ADAA history pair must be **per channel**. Drum drive is post-voice, pre-pan,
so one history pair per voice suffices (mono before pan).

**Filters.** The Simper TPT state-variable filter PolySynth already uses
(`PolySynthInstrument.swift:17-20`) gives LP/BP/HP from one structure; coefficients derived at
note-on. One-pole tilts for `tone`.

**Voice allocation.** Eight voices, **one instance each, monophonic, no stealing, no pool.** A
fixed 8-slot block allocated in `init` (the `PolySynthInstrument.swift:274-289` pattern: every
buffer allocated once, at maximum size, never resized). A retrigger of a sounding voice restarts
it through a **3 ms linear fade-out** rather than a hard cut — the hardware behaviour, and the
click-free one. Deliberate v1 limitation: a 3 s 808 kick tail retriggered on the next beat cuts
itself, exactly as an 808 does. The escape hatch, if wanted later, is a per-voice `voices` count —
additive, and the only reason it is not in v1 is that it would introduce the instrument's only
discrete parameter and a stealing policy, for a behaviour the hardware does not have.

---

### 2.1 Kick — 808 lineage (bridged-T self-oscillation, decomposed)

**Lineage.** The TR-808 bass drum is a bridged-T network biased near the edge of oscillation; a
trigger pulse rings it, and the ring's pitch and amplitude both decay out of the one circuit
(`docs/research/2026-09-19-synthesis-engines.md:255-259`, citing
[Perfect Circuit](https://www.perfectcircuit.com/signal/kick-drum-synthesis)). The standard software
decomposition — which is what we build — is **a sine oscillator plus two independent exponential
envelopes**, one on pitch (fast) and one on amplitude (slow)
(`…synthesis-engines.md:260-264`, citing [Unison.audio](https://unison.audio/808-drum/)).

**909 vs 808 is a preset, not a topology.** The TR-909 bass drum panel is `tune` / `attack` /
`decay`, and its character is a *deeper, faster* pitch sweep with a *shorter* body and a *harder*
click than the 808's long boom. Both are the same three blocks with different numbers. So there is
**no `character` enum** — the two lineages ship as two presets over one continuous topology. This
is what keeps the "zero discrete parameters" property true.

**Signal path, per sample:**

```
ap[n] = ap[n-1] * ca                  ca = pow(10, -3/(decay        * fs))    // amplitude env
pp[n] = pp[n-1] * cp                  cp = pow(10, -3/(pitchDecay   * fs))    // pitch env
f[n]  = tune * (1 + pitchAmount * pp[n])
φ[n+1] = frac(φ[n] + f[n]/fs)
body   = sin(2π φ[n]) * ap[n]

click  = noise[n] * ac[n] * snap      ac[n] = ac[n-1] * pow(10, -3/(0.004*fs))
         (click high-passed at 1.2 kHz, 1-pole — the beater, not the boom)

out    = adaaTanh((body + click) * (1 + 6*drive)) * levelCompensation(drive) * level
```

**Defaults (808):** `tune` 52 Hz, `decay` 0.62 s, `pitchAmount` 3.2, `pitchDecay` 0.045 s,
`snap` 0.18, `tone` 0.5, `drive` 0.12.
**909 preset:** `tune` 58, `decay` 0.26, `pitchAmount` 7.5, `pitchDecay` 0.014, `snap` 0.55,
`drive` 0.30.

With the 808 defaults the oscillator starts at `52 × 4.2 ≈ 218 Hz` and settles to 52 Hz — the
"tiny drop that reads as impact rather than tone" (`…synthesis-engines.md:261-262`).

**Params (10):** the core eight — `tune`, `decay`, `tone`, `snap`, `drive`, `level`, `pan`,
`velocity` — plus `pitchAmount` and `pitchDecay`. (Matches §3.5's table row.)

---

### 2.2 Snare — 909 lineage (two drumhead modes + gated noise)

**Lineage.** A tonal component of one or two pitched oscillators (the drumhead's vibratory modes)
plus a noise component through a lowpass→highpass chain, each with its own envelope, mixed
(`…synthesis-engines.md:265-268`, citing the
[McGill Nord Modular percussion chapter](https://cim.mcgill.ca/~clark/nordmodularbook/nm_percussion.html),
which specifies *"two triangle oscillators to provide the basic drumhead vibratory modes"* and
*"white noise source passed through a lowpass-highpass filter chain"*). The 909 panel's three
snare knobs are `tune` / `tone` / `snappy`; our `snap` **is** snappy.

**Signal path:**

```
tone1 = modalResonator(f = tune,                   T = decay)
tone2 = modalResonator(f = tune * partial2Ratio,   T = decay * 0.55) * 0.6
shell = (tone1 + tone2) * (1 - snap)

n[n]  = noise[n]
n[n]  → SVF bandpass(centre = noiseTone, Q = 1.1)  → 1-pole HP at 300 Hz
noise = n * an[n],   an[n] = an[n-1] * pow(10, -3/(decay*0.75*fs))
out   = adaaTanh((shell + noise*snap*1.4) * (1+5*drive)) * level
```

`tone` tilts the noise band: `noiseTone` is itself a parameter, and `tone` additionally moves a
post-mix 1-pole shelf so a single knob does the "duller/brighter" gesture.

**Defaults:** `tune` 180 Hz, `partial2Ratio` 1.83 (→ 329 Hz), `decay` 0.19 s, `snap` 0.55,
`noiseTone` 2200 Hz, `tone` 0.5, `drive` 0.10.

**UNVERIFIED:** 180 Hz / 1.83 are chosen from common software-808 practice and the "two modes"
architecture; I did **not** find a circuit-level source stating the TR-808's exact snare partial
frequencies. The ratio is a *parameter*, so an implementer or an agent can retune it; nothing in
the design depends on the number being historically exact.

**Params (10):** core 8 + `partial2Ratio`, `noiseTone`.

---

### 2.3 Closed hat and 2.4 Open hat — 808 lineage (six-square inharmonic cluster)

**Lineage, and why it is 808 and not 909.** The 808 hi-hat/cymbal circuit is **six square-wave
oscillators mixed with no precise tuning**, through **two bandpass filters** and gating circuits
with different time constants, then three high-pass filters
(`…synthesis-engines.md:269-273`; [McGill percussion chapter](https://cim.mcgill.ca/~clark/nordmodularbook/nm_percussion.html)).
The 909's hats are **samples**, not a circuit (§1.5) — so the 808 is the only synthesised hat
lineage there is, and we follow it.

**The six frequencies, sourced:** 800, 540, 522.7, 369.6, 304.4, 205.3 Hz
([Baratatronix, TR-808 cymbal/hi-hat synthesis](https://www.baratatronix.com/blog/cascadia-808-cymbal-hi-hat-synthesis)).
Same source: **bandpass 1 at 7100 Hz, bandpass 2 at 3440 Hz**; **closed-hat decay 50 ms (fixed in
hardware), open hat 90–600 ms, cymbal 350–1200 ms**. Those four numbers become our defaults and
our test bands directly. ⚠️ Honest caveat, also sourced: only the 800 Hz and 540 Hz oscillators are
tunable in the real circuit and measured units vary by up to ~20% from resistor tolerance
([Tiptop Audio measurements, via search](https://www.modwiggler.com/forum/viewtopic.php?t=123644)) —
so the *set* matters, the exact digits do not, and `tune` scales all six together.

**Signal path (shared bank, two voices):**

```
for k in 0..<6:  sq[k] = polyBLEP_square(phase_k),  f_k = F[k] * tune
sum  = Σ sq[k] * (1/6)
band = SVF_bandpass(sum, centre = 7100 * tone_scale(tone), Q = 1.6)
hp   = 1-pole highpass(band, 6000 Hz)
out  = hp * ah[n] * level          ah[n] = ah[n-1] * pow(10, -3/(decay*fs))
```

**polyBLEP is not optional here, and this is the one place I am overruling "circuit-accurate".**
Six naive squares at 205–800 Hz at 48 kHz fold a large set of odd harmonics back down. The
foldover is *inharmonic garbage that lands inside the hat's own passband*, and the hat's entire
identity is a *specific* inharmonic spectrum. Worse, foldover frequencies move the wrong way when
`tune` rises, so the aliasing would contaminate §8's `tune`-sweep assertion — the gate would be
measuring the artefact. The primitive already exists at
`Sources/DAWEngine/Instruments/PolySynthInstrument.swift:1168` (`polyBLEP`). Cost: one branch and a
short polynomial per oscillator per sample, on a voice that sounds for ≤ 600 ms.

**Closed-hat defaults:** `decay` 0.05 s (sourced), `tune` 1.0, `tone` 0.5, `snap` 0.5, `level` 0.7.
**Open-hat defaults:** `decay` 0.32 s (mid of the sourced 90–600 ms), otherwise identical.

They are **two separate named voices sharing one topology**, exactly as the hardware shares one
circuit behind two decay pots — and they are chocked against each other (§4).

**Params (8 each):** core 8, no extras.

---

### 2.5 Clap — 808 lineage (the four-pulse retrigger, which is the whole sound)

**Lineage, and the one exact number the sources give.** *"White noise is amplitude modulated by a
fast envelope"* and *"the envelope is triggered by a series of four pulses, each about 11 msec
apart"*, followed by a longer diffuse tail
([McGill percussion chapter](https://cim.mcgill.ca/~clark/nordmodularbook/nm_percussion.html)).
The three fast retriggers plus one long tail is what makes a clap read as many hands rather than
one noise burst. It is also the **single most testable feature in this instrument** (§8.5).

**Signal path:**

```
noise → SVF bandpass(centre = tune, Q = 1.4) → gate

gate envelope, built from a pulse counter (render-thread integers, no allocation):
  pulses 0,1,2 at n = 0, spread·fs, 2·spread·fs   → each: fast exp, T = 0.0045 s
  pulse  3      at n = 3·spread·fs                → tail:  exp, T = decay
  env[n] = burstEnv[n]*(1-0.35*snap) + tailEnv[n]*(0.55+0.45*snap)
out = bandpassed_noise * env * level
```

**Defaults:** `tune` 1000 Hz, `spread` 0.011 s (**sourced**), `decay` 0.28 s, `snap` 0.5,
`tone` 0.55, `drive` 0.05.

**UNVERIFIED:** the 1000 Hz bandpass centre is common practice, not a figure I sourced; `spread`
and the four-pulse structure *are* sourced.

**Params (9):** core 8 + `spread`.

---

### 2.6 Tom — modal, 808 lineage with a shallow pitch drop

**Lineage.** The 808 tom is a bridged-T like the kick but tuned higher, with a much shallower pitch
envelope and a stick-noise transient. Structurally: kick topology + a second inharmonic mode,
which is the modal generalisation `…synthesis-engines.md:278-280` names for toms specifically.

```
body   = sweepingSine(tune, pitchAmount, pitchDecay) * ae[n]      // as the kick, shallower
mode2  = modalResonator(f = tune * 1.52, T = decay * 0.4) * 0.35
stick  = noise * exp(T = 0.006) * snap, highpassed at 2 kHz
out    = adaaTanh((body + mode2 + stick) * (1+4*drive)) * level
```

**Defaults:** `tune` 120 Hz, `decay` 0.38 s, `pitchAmount` 0.45 (vs the kick's 3.2 — this is what
makes it a tom and not a kick), `pitchDecay` 0.08 s, `snap` 0.25.

**Params (9):** core 8 + `pitchAmount`. (`pitchDecay` is fixed at `0.18 × decay` for the tom to
hold the voice at 9 names; an implementer who wants it exposed should append it, which is legal —
names are not positional.)

**One tom, not three.** A three-tom kit is `tom2` / `tom3` — **purely additive** in the named-voice
scheme: two new scope names, no renames, no index shifts, no migration. That is the scheme paying
for itself, and it is the answer to "what happens when this grows."

---

### 2.7 Rim / clave — a single short ring

**Lineage.** The 808 rimshot is a very short, sharply band-limited pulse — effectively one resonant
ring with a tiny noise click; the clave is the same circuit with a longer, purer ring.

```
ring  = modalResonator(f = tune, T = decay)
ring2 = modalResonator(f = tune * 2.7, T = decay * 0.5) * tone
click = noise * exp(T = 0.0015) * snap
out   = (ring + ring2 + click) * level
```

**Defaults:** `tune` 1700 Hz, `decay` 0.028 s, `tone` 0.3, `snap` 0.4.
One voice covers both: `decay` 0.028 is a rim, `decay` 0.11 with `tone` 0.05 is a clave.

**Params (8):** core 8.

---

### 2.8 Cymbal — the hat bank through the *other* bandpass

**Lineage.** The same six-oscillator 808 bank, taken through **bandpass 2 at 3440 Hz** with a much
longer decay — and, per the source, in the real machine *"the cymbal's decay potentiometer only
controls the time of the envelope modulating the VCA for the lower 3440 Hz band pass filter"*
([Baratatronix](https://www.baratatronix.com/blog/cascadia-808-cymbal-hi-hat-synthesis)).
Sourced decay range 350–1200 ms.

```
sum   = the same six polyBLEP squares (independent phases; this voice has its own bank state)
lowB  = SVF_bandpass(sum, centre = band, Q = 1.1)  * aLong[n]     // T = decay
hiB   = SVF_bandpass(sum, centre = 7100,  Q = 1.6) * aShort[n]    // T = decay * 0.25
out   = (lowB + hiB * (1-tone)) * level
```

**Defaults:** `band` 3440 Hz (**sourced**), `decay` 1.1 s, `tune` 1.0, `tone` 0.45.

**Params (9):** core 8 + `band`.

**Why this voice earns its own entry rather than being "open hat with a long decay":** the decay
applies to the *lower* band only, and that asymmetry is the difference between a cymbal and a very
long hat. §8.8 asserts it as a cross-voice invariant (cymbal centroid must sit **below** closed-hat
centroid) — which is also the assertion that catches a copy-paste of the hat's filter constants.

---

## 3. ⭐ The parameter surface and how it is addressed

This is the hard design question in the brief, so it gets the most space.

### 3.1 The constraint, quoted

Two *opposite* laws live in this tree, and the drum machine sits on the boundary.

**Effects — positional, append-only forever.** `Sources/DAWCore/Effects.swift:4218-4223`:
*"⛔⛔ ORDER IS FROZEN AND APPEND-ONLY FOREVER. The INDEX of a spec in this array IS the automation
slot number (`storeAutomatedParam(slot:value:)`). Inserting a param in the middle …"* — and the
file is littered with `// slot: 0 …` maps and `// … APPENDED so the automation slot indices … never
move` comments (`Effects.swift:2960, 3001, 3063, 3084, 3191, 3830, 3975, 4079`).

**Instruments — name-addressed, explicitly NOT positional.**
`Sources/DAWCore/InstrumentParams.swift:18-24`, verbatim:

> ⚠️⚠️ SLOT POSITIONALITY DOES NOT TRANSFER, AND MUST NEVER BE ALLOWED TO. Effect automation slots
> are positional and append-only forever (`storeAutomatedParam(slot:)`). Instrument params are
> addressed **by name end to end** — the delivery path resolves a name to a field at publish time
> on the main actor, never by index on the render thread. So these arrays may be reordered freely,
> and **must not** acquire an index-addressed setter later. This is the single most likely future
> mistake in this file.

**So: the answer to the brief's question is that the instrument-side equivalent of
`EffectParamSpec.specs(for:)` — namely `InstrumentParamSpec.specs(for:)`
(`InstrumentParams.swift:115-161`) — does NOT carry the append-only slot constraint, and a written
law forbids it from acquiring one.** That is what makes two-level nesting tractable.

### 3.2 Decision: dotted `<scope>.<param>` on the existing `.instrumentParam` case

```
kick.tune          snare.snap          closedHat.decay     kit.accentDepth
```

Nine scopes: the eight voice names plus `kit` for the four kit-wide parameters. Both segments are
lowerCamelCase; the separator is `.`; the name is the whole string and is never split on the render
thread.

**Why it wins:**

- **It needs no new type, case, key or wire shape.** `AutomationTarget.instrumentParam(paramName:
  String)` (`Automation.swift:40`) already carries an arbitrary string, and its Codable already
  writes `{type:"instrumentParam", param:"…"}` reusing the existing `param` coding key
  (`Automation.swift:28-34, 66-68, 85-87`). `kick.tune` persists, round-trips and validates through
  code written months ago, unchanged.
- **The generic validator already handles it.** `Sources/DAWCore/ProjectStore+Modulation.swift:318-350`
  resolves purely through `InstrumentParamSpec.specs(for:)` / `discreteParamNames(for:)` /
  `isHosted(_:)` and builds its refusal text from `specs.map(\.name)`. **It needs zero changes** —
  once `specs(for: .drumSynth)` returns the table, `mod.addRoute` on `kick.tune` validates, and a
  typo like `kik.tune` is refused with the full valid-name list. That is the ONE-HOME design paying
  out, and it is evidence the dotted scheme is with the grain rather than against it.
- **`valueRange(in:)` already handles it.** `Automation.swift:119-131` looks the name up in
  `specs(for: descriptor.kind)`. Unchanged.
- **Names can be reordered, inserted and grown forever.** `tom2` / `tom3` (§2.6), a future
  `kick.subLevel` — all additive, no index moves, no migration, and §3.1's law explicitly permits
  reordering.
- **It reads well to an agent and to a human.** `"set kick.decay to 1.2"` needs no lookup table.

### 3.3 The two strongest alternatives, and why they lose

**Alternative A — a positional `pads: [DrumVoiceParams]` array (what the research doc proposed).**
`docs/research/2026-09-19-synthesis-engines.md:528-531` proposes exactly this:
`public struct DrumKitConfig { public var pads: [DrumVoiceParams] }`, one per pad slot.

**Rejected, and the research doc is overruled here.** An array index *is* positional addressing.
The moment anything addresses `pads[3].tune`, the array order is frozen forever and we have
imported the effect side's append-only slot law into the one file whose header
(`InstrumentParams.swift:18-24`) forbids it by name. It also makes every voice structurally
identical, which forces either a lowest-common-denominator parameter set or an `engine` enum per
pad — and that enum is a **discrete** parameter, which `ProjectStore+Modulation.swift:337-344`
would have to refuse, breaking "every parameter automatable" on the very first knob.
Named fields cost eight lines of struct and buy permanent stability.

**Alternative B — a new `AutomationTarget` case carrying the nesting structurally**, e.g.
`.drumVoiceParam(voice: String, param: String)`.

**Rejected.** It would add a Discriminator case, two coding keys and a decode branch to a type whose
doc comment says *"the exact wire and persistence shape agents and the bundle format depend on"*
(`Automation.swift:16-17`), and it would fork every downstream `switch` over `AutomationTarget`
(`Automation.swift:95-131`, `ModulationSnapshotBuilder.swift:273-281`,
`ProjectStore+Modulation.swift:318`, plus `ProjectOverview`, `AutomationLaneModel`,
`DemoRender`, `Commands`). The structure it adds is real but it buys nothing the dotted string does
not already give, and it costs a permanent widening of the project's most persistence-sensitive
enum. A string with a documented grammar and a validator that lists valid names on a typo is the
cheaper, equally safe answer.

### 3.4 The render-side code, and the one mechanical change required

Targets reach the render thread as POD. `ModulationSnapshot.Target.paramSlot: Int32` is documented
as *"Effect-param slot, or `InstrumentParamID.code`"* (`ModulationSnapshot.swift:94-95`), and that
code is explicitly **wire-local, not persisted** (`InstrumentParams.swift:69-72`: *"This is a
WIRE-LOCAL code carried inside one snapshot, not a persisted slot — nothing on disk or on the wire
ever sees it."*).

**Pack the two levels into the existing Int32. No POD widening.**

```
code = (voiceIndex << 8) | paramIndex        // voiceIndex 0…8 (8 = kit), paramIndex 0…15
```

⚠️ **But there is a blocker, and it is a silent one.**
`Sources/DAWEngine/Modulation/ModulationSnapshotBuilder.swift:255` reads:

```swift
guard let id = InstrumentParamID(rawValue: paramName),
      let spec = InstrumentParamSpec.specs(for: descriptor.kind)
          .first(where: { $0.name == paramName }),
      spec.modulatable != .refused
else { return nil }
```

`InstrumentParamID` is a flat 7-case enum (`InstrumentParams.swift:60-67`). `InstrumentParamID(rawValue: "kick.tune")`
is **nil**, so the guard fails and the route is **dropped from the snapshot** — after
`mod.addRoute` has already validated it and returned success. That is this tree's characteristic
failure exactly: a success response and a dead feature.

**Fix: move the code into the spec table.** Add `public let code: Int32` to `InstrumentParamSpec`
(`InstrumentParams.swift:29-54`), populate it from `InstrumentParamID.code` for `.polySynth`
(byte-identical) and from the packed drum code for `.drumSynth`, and replace the
`InstrumentParamID(rawValue:)` guard at `ModulationSnapshotBuilder.swift:255` with a read of
`spec.code`. This *removes* a name-to-enum round trip rather than adding one, and it makes the ONE
HOME table self-describing — which is what its header already claims it is.

⚠️ **`appliesAtNextNoteOn` must move with it, in the same change.** It is today a computed
property of `InstrumentParamID` (`InstrumentParams.swift:88-93`), not a field of
`InstrumentParamSpec`. The moment drum params stop resolving through `InstrumentParamID`, **nothing
carries the flag** — and `describeDrumKit` (§7) and the "Takes effect at the next note-on" spec
`note` both depend on it. Add `public let appliesAtNextNoteOn: Bool` to `InstrumentParamSpec`
beside `code`, populate it for `.polySynth` from the existing computed property (so the two cannot
disagree), and set it `true` for every drum parameter except `level` and `pan` (§3.5). Missing this
is a silent loss of a documented behaviour, not a compile error.

**Required positive control:** a test asserting that a `.polySynth` route on `cutoffHz` still
resolves to `paramSlot == 0`, `resonance` to 1, … `release` to 6, **and** that
`appliesAtNextNoteOn` still reads `true` for the four envelope params and `false` for the other
three — i.e. that the refactor moved no existing behaviour. Without it, this change is a silent
renumbering of every live modulation route.

**The second silent site, same shape:** `InstrumentParamSpec.currentValue(of:in:)`
(`InstrumentParams.swift:182-196`) guards `descriptor.kind == .polySynth` and returns nil
otherwise. `ModulationSnapshotBuilder.swift:265-267` uses it for `baseValue` and falls back to
`spec.defaultValue`. A drum route would therefore modulate around the **default**, not around the
value the user set — audible, wrong, and nothing fails. Needs a `.drumSynth` branch.

### 3.5 The table: 75 names

| Scope | Core 8 | Extras | Count |
|---|---|---|---|
| `kick` | tune, decay, tone, snap, drive, level, pan, velocity | pitchAmount, pitchDecay | 10 |
| `snare` | ″ | partial2Ratio, noiseTone | 10 |
| `closedHat` | ″ | — | 8 |
| `openHat` | ″ | — | 8 |
| `clap` | ″ | spread | 9 |
| `tom` | ″ | pitchAmount | 9 |
| `rim` | ″ | — | 8 |
| `cymbal` | ″ | band | 9 |
| `kit` | gain, velocityToTone, accentThreshold, accentDepth | — | 4 |
| | | | **75** |

**The core eight are the same eight names on every voice, and `snap` means something different on
each.** On the kick it is click level; on the snare, the snappy/noise balance; on the hats, attack
sharpness; on the clap, burst-vs-tail; on the tom, stick noise; on the rim, the click; on the
cymbal, attack. This is a deliberate trade: eight names an agent learns once, at the cost of one
name being polysemous. It is safe **only because `InstrumentParamSpec.note` exists**
(`InstrumentParams.swift:40-41`, *"Optional teaching line, surfaced verbatim by the describe
verbs"*) — so every voice's `snap` spec carries its own one-line meaning, and
`instrument.describeDrumKit` prints it. Without that field I would have used eight distinct names.

**The modulatability contract — one rule, stated once:**

> **Every drum parameter is `modulatable: .yes`. Every one except `level` and `pan` is
> `appliesAtNextNoteOn: true`.**

Because a one-shot latches its parameters at trigger, this is not a compromise — it is what the
hardware does, and it is musically sufficient because a drum pattern has many note-ons per bar.
`level` and `pan` are applied per-sample to the sounding voice (they are the voice's output stage,
not its topology), so they move continuously.

**The consequences are all good:**
- `discreteParamNames(for: .drumSynth)` returns `[]` — **the first instrument with no discrete
  parameters.** No `modulationTargetUnsupported(.discrete)` refusal exists for this instrument.
- No per-sample coefficient re-derivation, no 32-frame stride, no "block-rate modulation" zipper
  problem (`…synthesis-engines.md:442-458` defers that whole category; this instrument never
  enters it).
- The render-path contract is unchanged: `render()` allocates nothing, locks nothing, and derives
  coefficients at note-on — an *event*, not a per-sample cost.

The spec `note` for every latched parameter reuses PolySynth's exact phrasing
(`InstrumentParams.swift:140-141`): *"Takes effect at the next note-on."*

### 3.6 ⛔ The honest limit on the word "automatable"

**`Sources/DAWCore/ProjectStore.swift:3522-3537` refuses instrument-parameter automation lanes
outright**, for every instrument kind:

> instrument-parameter automation lanes are not supported yet — there is no render-side lane
> delivery for `track.instrument`. To modulate an instrument parameter now, use `mod.addRoute` with
> target `{type:"instrumentParam", param:"…"}`.

Confirmed at the delivery end: `AutomationSchedule` carries exactly three lane classes — volume,
pan, `effectParamTracks` (`AutomationSchedule.swift:74-78`), built from
`volumeLane`/`panLane`/`effectParamLanes` (`AutomationSchedule.swift:276-285, 326-329`).
`instrumentParam` appears **nowhere** in `Sources/DAWEngine/PlaybackGraph.swift`
(positive-controlled: the same grep finds `effectParamLanes` at `PlaybackGraph.swift:1955` and
`:1974` in that file, so the pattern and the file are both live). Instrument params reach the render
thread **only** through `ModulationSnapshot`
(`ModulationSnapshotBuilder.swift:252-268`, `ModulationEvaluator.swift:155`).

**So, stated plainly for the parent agent and the user:**

| | day one |
|---|---|
| All 75 names MCP-exposed, readable, settable | ✅ |
| All 75 names **modulatable** (`mod.addRoute`: LFO, step sequencer, macro, envelope follower) | ✅ |
| All 75 names as hand-drawn **timeline automation lanes** | ❌ — refused engine-wide, for every instrument |

This is **not a drum-machine gap** and the drum machine must not try to close it. But it will make
the gap *felt* — "draw the hat decay opening over eight bars" is a thing people will immediately
want. So:

**File a separate follow-on item now: `m39-dm-lanes`, instrument-parameter lane delivery.** And a
design note that makes it cheap: because every drum parameter is **note-on-latched** (§3.5), lane
delivery for `.drumSynth` does **not** need a per-sample cursor like `AutomationRenderer`'s effect
path. The lane need only be *sampled at each note-on instant* — an O(1) read of a sorted breakpoint
array at a known sample position, on an event that already happens. That is a materially smaller
piece of work than the general case, and the drum machine's design deliberately does not foreclose
it: the packed `code` (§3.4) is exactly the identifier such a path would carry.

**Route budget ceiling, stated because 75 > 64.** `ModulationLimits.maxRoutes = 64`
(`Sources/DAWCore/Modulation.swift:438`). So: every one of the 75 names is *addressable*, but at
most **64 modulation routes may exist on one strip**, across all target types.

⚠️ **One thing that reads as a ceiling here and is NOT one.** `Modulation.swift:434-438` says
routes and lanes *"SHARE ONE BUDGET: a modulated-but-unautomated effect param costs a synthetic
lane, so `lanes + modulatedEffectParams <= 64` on a strip"* — but the synthetic-lane mechanism it
describes is **effect-param-only**: `ModulationSnapshotBuilder.swift:125-130` filters
`case .effectParam(…)` and nothing else. Instrument routes consume `maxRoutes`; they do **not**
consume `AutomationSchedule.maxEffectParamTracks` slots. The shared-budget sentence therefore does
not bind drum parameters, and the doc should not repeat it as if it did.

**UNVERIFIED — what happens on route overflow.** I read `.prefix(maxEffectParamTracks)` at
`AutomationSchedule.swift:90-91`, but that is the **effect-lane** path. I did **not** read the code
that trims routes past `ModulationLimits.maxRoutes`, so I cannot say whether a 65th route is
refused loudly or dropped silently. An implementer must read it before relying on either.
Regardless, `instrument.describeDrumKit` should report `routesUsed / routeBudget` so an agent can
see the ceiling before it reaches it.

---

## 4. Choke groups

**Reuse the concept and the numeric range; do NOT reuse `SamplerZone.chokeGroup`.**

`SamplerZone.chokeGroup: Int?` (`Sources/DAWCore/Model.swift:2433`) with
`chokeGroupRange: ClosedRange<Int> = 0...63` (`Model.swift:2452`) is a property of a **sampler
zone** — a key-mapped region of an audio file. A drum voice is not a zone and a `.drumSynth`
descriptor has no zones. Borrowing the field would mean either reading a sampler payload from a
drum instrument (nonsense on the wire and in `describeSampler`) or a shared base type that exists
only to be shared.

**Design:**
- `DrumVoiceParams.chokeGroup: Int?`, additive-optional, clamped through **the same
  `SamplerZone.chokeGroupRange` constant** (`Model.swift:2452`) — ONE home for the number, so the
  two can never disagree about what 63 means. (It is the only thing shared.)
- **Defaults: `closedHat` and `openHat` both in group 0; every other voice nil.** That reproduces
  the hardware — the 808/909 hats are one circuit, so either cuts the other — and it means the kit
  grooves correctly with zero configuration, which matters for a beginner-facing product.
- Semantics are **symmetric**: any voice in group *g* cuts every *other* sounding voice in group
  *g*. Not "closed cuts open" as a special case.

**Copy the sampler's mechanism exactly — three details, each of which was a bug once:**

`SamplerInstrument.swift:2198-2209` and its comments at :2044-2046:
1. **Fire the choke BEFORE writing the new voice's slot**, so a note can never choke itself.
2. **A per-note-on `chokeFiredMask` bitmask**, so one note-on triggering several same-group voices
   chokes that group at most once.
3. **The range is resolved to −1…63 at load**, so `1 << chokeGroup` cannot shift out of range
   (`SamplerInstrument.swift:236-240`).

**One deliberate difference: what happens to the choked voice.** The sampler pushes it into its
**release stage** and lets the release envelope fade it (`SamplerInstrument.swift:2048-2062`;
:2037-2038 notes there is *"no hard cut, no invented constant"*). A drum voice has no release stage
— it is one decaying envelope. So a choked drum voice **switches its envelope coefficient to a
3 ms −60 dB exponential** and keeps running the same output path. Same principle (never a hard
cut), expressed in this instrument's own vocabulary, and it is a **measurable** quantity: §8.9
asserts the choked tail is ≥ 60 dB down within 5 ms of the choking note-on and that no sample-to-
sample step exceeds a click threshold.

`chokeGroup` is the one field that is *not* in the 75 names: it is structural, not continuous, and
exposing it as a modulation target would be the instrument's only discrete parameter. It is set
through the kit payload (§7), and it is reported by `instrument.describeDrumKit`.

---

## 5. Velocity and accent

This is what makes the kit groove rather than tick, and it is two different mechanisms because two
different callers need them.

**Velocity is available.** `ScheduledMIDIEvent.velocity: UInt8`
(`Sources/DAWEngine/MIDISchedule.swift:19`) — nothing new is needed to read it.

**(a) Per-voice `velocity` (0…1, one of the core eight).** How much a note's velocity moves the
voice. At 0 every hit is identical — which is *correct* and wanted for a machine-even hi-hat
pattern. At 1, full dynamics.

It drives **two** things, which is the point:

```
v      = velocity / 127
vScale = 1 - voice.velocity * (1 - v)              // amplitude
tShift = voice.velocity * kit.velocityToTone * (v - 0.5) * 2    // timbre, bipolar
```

`tShift` opens the tone filter and *shortens* the pitch-envelope decay on a hard hit. **Amplitude
alone is what "ticks".** A real drum struck harder is *brighter*, not merely louder — the same
principle `docs/research/2026-09-19-synthesis-engines.md:222-224` names as the difference between
"a patch that sounds identical in every register/dynamic and one that" does not. This is the
cheapest large-perceptual-payoff item in the instrument.

**`kit.velocityToTone` (0…1, default 0.4)** is the kit-wide ratio between the two effects, so a
user picks "how dynamic" per voice and "how much of that is timbre" once.

**(b) The accent bus — `kit.accentThreshold` (1…127, default 100) and `kit.accentDepth`
(0…1, default 0.25).** A note at velocity ≥ threshold gets an extra `accentDepth` of level and an
extra half-share of `tShift`, on *every* voice.

**Why both, when (a) subsumes (b) mathematically:** because the 808's accent is a *step property*,
not a velocity, and an agent composing a pattern thinks in those terms — "accent beats 1 and 3."
An MCP client that emits velocity 110 on accented steps and 80 elsewhere gets hardware-correct
behaviour with no knowledge of our velocity curve. An agent that wants continuous dynamics gets
those too. Two vocabularies, one mechanism underneath. Both are continuous, both are modulatable,
neither is discrete.

**Defaults per voice** (`velocity`): kick 0.55, snare 0.85, closedHat 0.75, openHat 0.7,
clap 0.6, tom 0.8, rim 0.7, cymbal 0.8. The kick is lowest on purpose: a kick that jumps around in
level is the single most common way a programmed beat stops sounding solid.

---

## 6. Every site that must change to add an instrument kind — the real census

The brief warns that the *effect* path was believed to have six hand-written sites and has **eight**,
two of them not compiler-forced. **The instrument path has the same trap, and worse.** I traced the
newest kind (`.soundBank`, m10-n) and `.sampler` across `Sources/`.

**37 sites. 16 are compiler-forced. 21 are not.**

⚠️ **The unit is a SITE — one edit location — not one file.** Six of the Class B rows are six
separate members of a single file (`ProjectDocument.swift`), and Class A's sixteen switches live in
twelve files. Counting by file would understate Class B by five and is the reason an earlier
draft of this section said "31/13/18"; those figures are superseded.

The classification matters more than the total: a forced site cannot ship broken, an unforced one
ships broken *with a success response*.

### Class A — compiler-forced `switch` over `InstrumentDescriptor.Kind` (16 sites in 12 files; safe)

Adding a case breaks the build until each is handled.

| # | Site | What it decides |
|---|---|---|
| A1 | `Sources/DAWEngine/PlaybackGraph.swift:558-567` | instrument factory → `DrumSynthInstrument(params:)` |
| A2 | `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:764-768` | not an AU-hosted kind |
| A3 | `Sources/DAWAppKit/InstrumentPickerModel.swift:587-598` | `displayName` → "Drum Machine" |
| A4 | `Sources/DAWCore/InstrumentParams.swift:115-161` | **`specs(for:)` — the 75-row table** |
| A5 | `Sources/DAWCore/InstrumentParams.swift:167-172` | `discreteParamNames` → `[]` |
| A6 | `Sources/DAWCore/ProjectStore+TimbreLiveness.swift:163-181` | liveness detail string |
| A7–A10 | `Sources/DAWCore/MIDIControllerRouting.swift:95-121, 188-189, 331-333, 462-463` | four switches: CC routing, hosted-ness, offline sampling |
| A11 | `Sources/DAWCore/ProjectStore.swift:3073-3078` | **`instrumentNodeIdentityChanged`** — see below |
| A12 | `Sources/DAWCore/InstrumentControllerSupport.swift:143-146` | prose name, "the drum machine" |
| A13 | `Sources/DAWCore/InstrumentFamilyResolution.swift:354-361` | carries no GM family |
| A14 | `Sources/DAWApp/ViewUIWireSurface.swift:272-300` | `view.*` editor routing |
| A15 | `Sources/DAWApp/Instrument/InstrumentPickerView.swift:223-228` | picker row → editor |
| A16 | `Sources/DAWApp/Components/InstrumentChip.swift:63-70` | glyph |

(16 switches in 12 files, shown as 13 table rows — `MIDIControllerRouting`'s four share one row.
Counted by measuring the distinct file paths in the table above, not by eye.)

⭐ **A11 is a decision, not a chore.** `instrumentNodeIdentityChanged` must return **`false`** for
`.drumSynth` kit edits (the `.polySynth` rule at `ProjectStore.swift:3078`, not the `.sampler` zone
rule at :3075). A kit edit is an atomic snapshot publish, never a node rebuild — which is what keeps
mid-take kit edits legal on a routed strip (`ProjectStore.swift:4084-4087` refuses a node-identity
change mid-take). Getting this wrong makes every drum knob turn refuse during recording.

### Class B — hand-written lists, initialisers and manual Codable (16; compile clean, ship wrong)

| # | Site | What silently happens if you miss it |
|---|---|---|
| B1 | `Sources/DAWAppKit/InstrumentPickerModel.swift:201-212` — `builtIns` is a hand-built **array literal** | The instrument is **unpickable in the UI**. Zero compile error. Wire-only feature. |
| B2 | `Sources/DAWCore/Model.swift:1647-1682` — property + init with all-defaulted payload args | Every existing `InstrumentDescriptor(...)` call site compiles unchanged and drops `drumKit` |
| B3 | `Sources/DAWCore/ProjectStore.swift:3958-3994` — `setInstrument` signature (22 optionals today) | The kit is unsettable over the wire |
| B4 | ⛔⛔ `Sources/DAWCore/ProjectStore.swift:4022-4078` — the explicit rebuild | **DATA LOSS with a success response** |
| B5 | `Sources/DAWCore/ProjectStore+SliceToSampler.swift:342-347` — rebuild copying payloads forward | Chopping a clip to a sampler **wipes the user's kit** |
| B6 | `Sources/DAWCore/ProjectDocument.swift:~912` — `InstrumentDocument` property | — |
| B7 | `Sources/DAWCore/ProjectDocument.swift:914` — `CodingKeys` | **The kit never persists.** No compile error, no runtime error, no warning |
| B8 | `Sources/DAWCore/ProjectDocument.swift:916-924` — `init(from: InstrumentDescriptor, mediaRefs:)` | Kit dropped on save |
| B9 | `Sources/DAWCore/ProjectDocument.swift:926-934` — `init(from decoder:)` | Kit dropped on open |
| B10 | `Sources/DAWCore/ProjectDocument.swift:936-946` — `encode(to:)` | Kit dropped on save |
| B11 | `Sources/DAWCore/ProjectDocument.swift:1033` — `toDescriptor` (defaulted args again) | Kit dropped on open |
| B12 | `Sources/DAWCore/InstrumentParams.swift:176-178` — `isHosted` is an **expression**, not a switch | **Correct by luck** — a new kind reads as not-hosted, which is right for `.drumSynth`. Named so nobody assumes it was checked. |
| B13 | `Sources/DAWCore/InstrumentParams.swift:182-196` — `currentValue(of:in:)` guards `kind == .polySynth` | Every drum route modulates around the **default**, not the user's value. Audible, wrong, nothing fails. |
| B14 | `Sources/DAWAppKit/ExplainModel.swift:284` — the explain-id enum (`case polySynthEditor`, `case samplerEditor`) | The drum editor has no explain id; `.explainable(…)` cannot reference it |
| B15 | `Sources/DAWAppKit/ExplainModel.swift:649-656` — the `ExplainEntry` dictionary literal | The drum editor's "what is this panel" text is absent. Hand-written dictionary; no compile error |
| ⛔ B16 | `Sources/DAWControl/CopilotCatalog.swift:392` — `enumValues: ["testTone", "polySynth", "audioUnit"]` for `track.setInstrument`'s `kind` | The in-app AI copilot cannot select the drum machine. **⭐ This list is ALREADY STALE — it omits `sampler` and `soundBank`, both of which have shipped.** A pre-existing rot finding surfaced by this trace; worth fixing in the same pass, and proof that this class of site rots silently. |

⛔⛔ **B4 is the same trap the brief warns about, and this tree has already been bitten by it — the
warning is in the file.** `ProjectStore.swift:4038-4058`, verbatim:

> This is an EXPLICIT initialiser call, so a field omitted here does not inherit `p`'s value — it
> takes `PolySynthParams`' own `nil` default, on EVERY call, and the method returns success. … The
> moment the wire could set them it became DATA LOSS with a success response: a user brightens the
> filter and their unison stack, sub-oscillator and drive are gone. That is m33-j's shape exactly
> (`clip.addAudio` deleted the clips it overlapped and answered OK) … **⚠️ A SIXTEENTH FIELD ADDED
> TO `PolySynthParams` AND NOT ADDED HERE WILL COMPILE, SHIP, AND DELETE ITSELF.**

and the mirror warning on the signature at `ProjectStore.swift:3970-3976`: *"A field accepted here
and not named there is not 'ignored' — it is DESTROYED on every unrelated call, with a success
response."*

**Mitigation, and it is a design constraint not a review note: the drum kit overlay must go through
the struct, never through an initialiser argument list.**

```swift
var kit = current.drumKit ?? DrumKitParams()     // mutate in place
if let drumKit { kit = drumKit }                 // wholesale replace
if let drumParam { kit[drumParam.name] = drumParam.value }   // name-addressed single set
```

A `var` + mutation cannot drop a field it does not mention. An initialiser list can, silently, on
every unrelated call. **75 parameters is far past the point where a human can be trusted to keep
two lists in sync**, which is exactly why §7 puts the per-parameter path on a *name* rather than on
75 more optional arguments.

### Class C — type-cast dispatch with `default: break` (2; the worst kind)

| # | Site | What silently happens |
|---|---|---|
| ⛔ C1 | `Sources/DAWEngine/PlaybackGraph.swift:1728-1737` | **Every drum parameter edit succeeds and is never delivered to the render thread, for the life of the session.** |
| ⛔ C2 | `Sources/DAWEngine/Modulation/ModulationSnapshotBuilder.swift:252-268` | Every drum modulation route is dropped from the snapshot after `mod.addRoute` returned success (§3.4) |

C1 in full — this is the instrument path's version of the brief's "two sites not compiler-forced":

```swift
if track.kind == .instrument {
    switch instrumentNodes[track.id]?.instrument {
    case let synth as PolySynthInstrument:
        synth.apply(params: (track.instrument ?? .default).polySynth)
    case let sampler as SamplerInstrument:
        sampler.apply(params: (track.instrument ?? .default).resolvedSampler)
    default:
        break                    // ⛔ a DrumSynthInstrument lands here
    }
}
```

It is a `switch` over an **existential with a `default:`**, not over the `Kind` enum. Adding
`.drumSynth` to `Kind` does not break this file. The instrument constructs, renders, sounds, and
**never receives a parameter change**. Every test that constructs an instrument with its params and
renders will pass; only a test that *edits a parameter on a live graph and re-renders* fails. §8.10
plants exactly that.

### Class D — cross-language and documentation (3; no compiler anywhere)

| # | Site | What silently happens |
|---|---|---|
| D1 | `Sources/DAWControl/Commands.swift` — `track.setInstrument` kind parsing + describe verbs (`Commands.swift:295-338` is the verb registry; `:2118` is `instrument.describeSynth`) | Kind unsettable over the wire |
| ⛔ D2 | `mcp-server/src/server.ts:2122` — `z.enum(["testTone","polySynth","sampler","audioUnit","soundBank"])` | **No agent can ever select the instrument.** The MCP layer rejects the call before it reaches the app. Hand-written, in another language, no compiler on earth catches it. |
| D3 | `claude-plugin/skills/daw-wire-reference/SKILL.md`, `mcp-server/README.md`, `docs/ROADMAP.md` | `node scripts/gates/doc-count-drift.mjs` reddens (this is the count pin, and it is *supposed* to redden) |

### Related but requiring NO change — worth knowing

- `Sources/DAWCore/ProjectStore+Modulation.swift:318-350` — the route-validation and refusal
  taxonomy is **fully generic** over `InstrumentParamSpec`. Zero changes. Evidence the ONE HOME is
  real.
- `Sources/DAWCore/Automation.swift:95-131` — `valueRange(in:)` resolves any instrument param by
  name through the same table. Zero changes.
- `Sources/DAWAppKit/InstrumentPickerModel.swift:625-636` — `InstrumentChoice.builtIn(InstrumentDescriptor.Kind)`
  carries the `Kind` itself, and `isCurrent` compares `descriptor.kind == kind`
  (`InstrumentPickerModel.swift:548-552`). `.drumSynth` rides through untouched. **Checked, not
  assumed** — a selection enum that enumerated kinds would have been a Class B site.
- `Sources/DAWCore/ProjectOverview.swift:283-290` — `overviewInstrumentName` returns
  `descriptor.kind.rawValue`, a passthrough. Zero changes. (Its doc comment's list
  `("polySynth", "sampler", "testTone")` is stale prose that already omits two shipped kinds —
  harmless here because the code does not read it, but the same staleness in
  `CopilotCatalog.swift:392` **is** live, which is Class B16.)
- `Sources/DAWAppKit/PadGridModel.swift:222-223` — the pad grid's live zones are *"empty when the
  track … plays something other than the sampler"*. The 4×4 grid based at note 36
  (`Sources/DAWAppKit/PadGridGeometry.swift:33-35, 53-54, 101-103` — *"Every MPC since the 60 and
  every Ableton Drum Rack lays C1 (36) at the bottom-left square"*) is the obvious surface for this
  instrument, and notes **36–43** map one-to-one onto our eight voices. **Extending the pad grid to
  `.drumSynth` is wave item (4), "loop/drum workflow depth" — not this item.** Listed so the
  sequencing is deliberate rather than forgotten.

### Summary for the brief's question

> **"For EFFECT kinds this project believed there were six hand-written sites and there are actually
> EIGHT … Assume the instrument path has the same trap and go find out."**

**It does, and it is larger.** The instrument path has **37 sites, of which 21 are not
compiler-forced** — sixteen hand-written lists/initialisers/Codable members (Class B), two
type-cast dispatches with `default: break` (Class C), and three cross-language/doc sites (Class D).
The two worst are **C1** (`PlaybackGraph.swift:1728-1737` — every parameter edit silently
undelivered) and **B7** (`ProjectDocument.swift:914` — the kit never persists), and neither
produces a compile error, a runtime error, or a log line.

---

## 7. Wire and MCP surface

**Additive only. No live command or tool is renamed.** (Standing constraint; and
`Automation.swift:16-17` notes the persistence shape is depended on by agents and the bundle
format.)

### Wire (DAWControl)

| Verb | Shape | Notes |
|---|---|---|
| `track.setInstrument` | **extend**: `kind` accepts `"drumSynth"`; new optional `drumKit` object | The `.sampler`/`.audioUnit`/`.soundBank` wholesale-payload precedent (`ProjectStore.swift:4075-4077`) |
| `instrument.setDrumParam` | **new**: `{trackId, name, value}` | The per-parameter path. `name` is a dotted `<scope>.<param>`. Overlay via struct mutation (§6 B4) |
| `instrument.describeDrumKit` | **new**: read-only | Modelled on `instrument.describeSynth` (`Commands.swift:2118-2177`) |
| `instrument.listDrumPresets` / `instrument.loadDrumPreset` | **new** | `"808"`, `"909"`, `"acoustic"`, `"lofi"`, `"trap"` — the two lineages plus three (§2.1) |

⛔ **Do NOT add 75 optional arguments to `setInstrument`.** That signature already carries 22
(`ProjectStore.swift:3958-3994`) and each one must be hand-mirrored in the rebuild at :4022-4078 or
it deletes itself (§6 B4). 75 more would make that mirror-pair unmaintainable by construction. The
wholesale payload plus a **name-addressed** single-parameter setter is the shape the name-addressing
decision (§3.2) naturally implies — one setter for all 75 names, no list to keep in sync.

**`instrument.describeDrumKit` response** (following `describeSynth`'s three load-bearing features,
`Commands.swift:2123-2143`):

```
{ trackId, kind, isActiveInstrument,
  voices: { kick: { params: { tune: {value, effective, default, min, max, unit, curve,
                                    meaning, modulatable, appliesAtNextNoteOn}, … },
                    chokeGroup }, … },
  kit: { … },
  parameterCount: 75, order: ["kick.tune", …],
  routesUsed, routeBudget,                      // the §3.6 ceiling, visible before it bites
  warnings: [ … ] }
```

**Warnings** carry describeSynth's rule (`Commands.swift:2131-2136`: *"A setting that is accepted,
stored, echoed back and silent is this tree's characteristic failure"*). For this instrument the
gated settings are: `pitchDecay` at `pitchAmount == 0` (does nothing), `clap.spread` at
`snap == 1.0` (tail only), `cymbal.tone` at `decay` below ~0.2 s (the short band dominates), and
`velocity` at `kit.velocityToTone == 0` (amplitude only). Each must warn.

**`isActiveInstrument`** matters here for the same reason as describeSynth
(`Commands.swift:2137-2142`): `InstrumentDescriptor` carries *every* kind's payload across kind
switches (`Model.swift:1648-1650`), so a track can hold a fully-dialled kit while playing a sound
bank. The verb answers for the kit either way and says which.

### MCP (`mcp-server/src/server.ts`)

Mechanical name mirroring, per the `instrument_describe_sampler` / `instrument_describe_synth`
precedent (`Commands.swift:2157-2161`): `instrument_set_drum_param`,
`instrument_describe_drum_kit`, `instrument_list_drum_presets`, `instrument_load_drum_preset`.
**+4 tools, +4 wire commands.** No exception-table entry needed.

⛔ **`server.ts:2122`'s zod enum must gain `"drumSynth"` or none of this is reachable** (§6 D2), and
`track_set_instrument`'s schema needs the `drumKit` object. The zod schema cannot call the app at
runtime, so — following the honesty note the tree already wrote for m39-g
(`Commands.swift:2165-2176`) — parameter bounds in the schema are **re-typed** from the same
`static let …Range` constants, and `instrument_describe_drum_kit` stays the **runtime authority**.

`node scripts/gates/doc-count-drift.mjs` is the command-count pin and must be re-run and re-based
after this lands.

---

## 8. Verification plan

The governing fact, from the brief and from this tree's own history: **an effect shipped completely
INERT with 24 green unit tests** (`scripts/demos/render-variants.mjs:652-660`). And:

> ⚠️⚠️ **READ THIS BEFORE TRUSTING A PASS: THE IMPLICATION RUNS ONE WAY.** Identical bytes prove the
> axis did NOTHING. **Distinct bytes prove NOTHING AT ALL.** Measured 2026-09-20: planting
> `shapedFraction → 0` in the transient shaper — the shaper never shapes, a completely inert effect
> — still produced four DISTINCT renders, because the variants' per-variant `outputDb` loudness
> trims differ. This check exited 0 on a dead feature.
> — `scripts/demos/render-variants.mjs:640-650`

**Therefore every gate below asserts a physical quantity with a number and a tolerance.** Nothing in
this plan passes on distinctness.

### 8.0 Measurement methods

- **Fundamental / partial energy:** Goertzel. The per-test-file helper convention exists —
  `Tests/DAWEngineTests/FXPack1Tests.swift:32-43`, `goertzel(_ samples: [Float], frequency: Double,
  in range: Range<Int>) -> Double` returning a normalised magnitude, with `dB(_:)` at :45. Copy it
  into `DrumSynthTests.swift` (the house convention — `goertzel` appears in ~20 test files).
- **Decay time:** windowed RMS in 2 ms hops; the −60 dB time is the first hop whose RMS is 60 dB
  below the peak hop.
- **Spectral centroid:** the project's own `Sources/DAWEngine/Analysis/AudioContentAnalyzer.swift`
  (reachable over the wire via `clip.analyzeAudio`), or in a shell gate
  `ffmpeg -hide_banner -af aspectralstats`. ⚠️ **`-v error` SUPPRESSES `astats`/`ebur128`/
  `aspectralstats` summaries — they log at INFO.** Use `-hide_banner`, never `-v error`.
- **Instantaneous pitch (for sweeps):** zero-crossing count per window. Cheap, robust, and it
  measures the thing a pitch envelope *is*.

### 8.1 Kick — `Tests/DAWEngineTests/DrumSynthKickTests.swift`

Defaults: `tune` 52, `decay` 0.62, `pitchAmount` 3.2, `pitchDecay` 0.045.

| Assertion | Number |
|---|---|
| Fundamental is where `tune` says | Goertzel@52 Hz over [0.15 s, 0.45 s] ≥ **12 dB** above both @26 Hz and @104 Hz |
| The pitch sweep exists | **first full period** (time between the first two same-direction zero crossings, ≈ 4.8 ms at the swept-start pitch) vs. a period measured at 300 ms (≈ 19.2 ms at 52 Hz): ratio ≥ **2.5**. ⚠️ **NOT a zero-cross *rate* over a short window** — [0, 8 ms] holds only ≈2.4 crossings, so a rate estimate quantises to 2 or 3 and passes by luck of rounding rather than by physics. |
| `decay` means its −60 dB time | −60 dB at **0.62 s ± 15%** |
| `tune` tracks | at `tune` 40 / 52 / 80, the measured fundamental is within **±3%** of each |
| One-shot | peak occurs within the first **5 ms** |
| `drive` adds harmonics, not level | at `drive` 0→0.8: Goertzel@104 Hz rises ≥ **10 dB**; integrated LUFS moves ≤ **1.5 LU** |

### 8.2 Snare

| Assertion | Number |
|---|---|
| Both drumhead modes present | Goertzel@180 and @329 each ≥ **15 dB** above @250 Hz (a deliberate non-partial control) over [5, 60 ms] |
| `snap` is a noise axis, monotonically | centroid at `snap` 0/0.33/0.66/1.0 is **strictly increasing**, total rise ≥ **800 Hz** |
| `partial2Ratio` moves partial 2 and not partial 1 | at ratio 1.5 vs 1.83: @270 Hz rises ≥ 12 dB, @180 Hz moves ≤ **1.5 dB** |
| `decay` | −60 dB at **0.19 s ± 15%** |

### 8.3 / 8.4 Closed hat and open hat

| Assertion | Number |
|---|---|
| It is a hat, not a tone | spectral centroid over the full tail ≥ **6000 Hz** |
| Low end is absent | energy below 500 Hz ≤ **−30 dB** relative to total |
| Closed-hat decay | −60 dB at **0.05 s ± 20%** (the sourced hardware value) |
| Open-hat decay | −60 dB at **0.32 s ± 20%** |
| The two are genuinely different voices | openHat −60 dB time ≥ **4×** closedHat's at defaults |
| `tune` scales the oscillator bank, and the filters do not follow | `tune` 1.0 → 2.0 raises centroid by ≥ **500 Hz** ⚠️ **this fixture must use tune ≠ 1.0** — see §8.11 plant P3 |
| No foldover (polyBLEP is working) | ⚠️ **Asserted on the square-wave primitive IN ISOLATION, not in situ.** Render one `polyBLEP_square` at 800 Hz for 200 ms and assert the summed energy at the non-harmonic alias frequencies `\|fs − h·f\|` for h = 31…59 is ≥ **40 dB** below the fundamental; a naive square fails by ≥20 dB. **An in-situ test cannot discriminate this** — the fixed 7100 Hz BPF + 6000 Hz HP attenuate everything below ~2 kHz regardless of the oscillator, so a below-200-Hz energy bound is a plant multiplied by zero (§8.12's own warning, applied to itself). Aliases from a 205–800 Hz square land in the kHz region, *inside* the passband, where the hat's legitimate content also is. |

### 8.5 Clap — the retrigger structure is the signature assertion

| Assertion | Number |
|---|---|
| **Four pulses** | RMS in 2 ms hops over [0, 45 ms] has ≥ **3 local maxima**, consecutive spacing **11 ms ± 3 ms** |
| `spread` moves them | at `spread` 0.020: spacing **20 ms ± 4 ms** |
| The tail exists | RMS at 150 ms ≥ **−45 dBFS**, and −60 dB at **0.28 s ± 20%** |
| Band placement | centroid within **[700, 2200] Hz** |

**This is the best assertion in the plan.** Nothing else in the instrument produces a periodic
amplitude comb at 11 ms. A plant on the retrigger count reddens this and *only* this.

### 8.6 Tom / 8.7 Rim

| Voice | Assertion | Number |
|---|---|---|
| Tom | fundamental | Goertzel@120 ≥ **12 dB** above @240, over [20, 120 ms] |
| Tom | shallow sweep — **and it is a tom, not a kick** | zero-cross ratio [0,8 ms]:[200,300 ms] between **1.1 and 1.6** (the kick's is ≥ 2.0; these bands do not overlap) |
| Rim | ring frequency | Goertzel@1700 ≥ **15 dB** above @850 and @3400 |
| Rim | it is *short* | RMS after **80 ms** ≤ **−70 dBFS**; −60 dB within **40 ms** |

### 8.8 Cymbal — the cross-voice invariant

| Assertion | Number |
|---|---|
| Long tail | −60 dB at **1.1 s ± 20%** |
| Band placement | centroid ≥ **4000 Hz** |
| ⭐ **Not a copy of the hat** | cymbal centroid is **at least 1500 Hz BELOW** closedHat centroid at both voices' defaults (3440 Hz band vs 7100 Hz band) |

That last row is the one that catches the most likely implementation error — pasting the hat's
filter constants into the cymbal — which every per-voice test would otherwise pass.

### 8.9 Choke

| Assertion | Number |
|---|---|
| Closed hat cuts open hat | openHat triggered at t=0 with `decay` 0.32; closedHat at t=0.1 s. openHat's contribution at t=0.11 s is ≥ **60 dB** below its level at t=0.095 s |
| It is a fade, not a cut | **RMS in 0.25 ms hops** across [0.100, 0.106 s] decreases monotonically, with no hop-to-hop drop greater than **6 dB** (a hard cut gives one drop > 30 dB). ⚠️ **NOT a sample-to-sample step bound** — a 7 kHz hat at amplitude 0.7 has legitimate per-sample deltas up to `2·0.7·sin(π·7000/48000) ≈ 0.6`, so a 0.08 step threshold reddens on a *correct* fade. Measure the envelope, not the waveform. |
| Choke is symmetric | the reverse order (closed then open) also chokes |
| Non-grouped voices do not choke | a kick at t=0.1 s leaves the openHat tail within **0.5 dB** of the un-choked control |
| Self-choke is impossible | two openHats 300 ms apart both sound (the `SamplerInstrument.swift:2044-2046` "fire before writing the slot" rule) |

### 8.10 The two structural tests that catch Class B and Class C

**⭐ The spec-table-driven consumer test — `DrumSpecTableConsumerTests.swift`.** Iterate
`InstrumentParamSpec.specs(for: .drumSynth)` — **all 75 rows, driven off the table, never a
hand-written list** (the brief's own law: *a list that reads as a census had already lost a kind*;
drive it from the table the way kind-pins are driven from `Kind.allCases`). For each row: render the
owning voice at `spec.defaultValue`, then at each end of `spec.range`, and assert a stated
observable moves by a stated minimum. **A parameter present in the table with no render-path
consumer reddens.** This is the m39-e inert-LFO catch, generalised to every parameter at once, and
it is the single highest-value test in this plan.

**The live-graph parameter-delivery test — the Class C1 catch.** Build a graph, play, **edit
`kick.decay` on the live store mid-session**, re-render, and assert the measured decay time changed.
Every test that constructs an instrument with params and renders it will pass even with
`PlaybackGraph.swift:1728-1737` unchanged. Only this one fails.

**The persistence round-trip test — the Class B7 catch.** Set a non-default value on **every one of
the 75 names**, save the project bundle, open it, and assert whole-struct equality of
`DrumKitParams`. Whole-struct, not field-by-field: the `richnessSurvivesAnUnrelatedKnobEdit` rule
(`ProjectStore.swift:4055-4058` — *"The whole-struct equality assertion in that test is the only
thing that catches it; keep it"*).

**The unrelated-edit test — the Class B4 catch.** Set a full kit; then call `setInstrument` changing
only `cutoffHz`; assert `DrumKitParams` is **whole-struct identical**. This is
`richnessSurvivesAnUnrelatedKnobEdit`'s direct analogue and it must be **written first and watched
to fail** before the overlay is implemented (as that test was — `ProjectStore.swift:4051-4053`:
*"was written BEFORE this block and watched to fail: all fifteen reddened, the `cutoffHz` control
passed"*).

**The polySynth non-regression positive control — the §3.4 catch.** After moving `code` into
`InstrumentParamSpec`: assert a `.polySynth` route on `cutoffHz` still resolves to `paramSlot == 0`,
`resonance` → 1, … `release` → 6. Without this, the refactor silently renumbers every live route.

### 8.11 ⛔ The demo gate — `scripts/gates/m39dm-drum-physics.mjs`

Modelled on `scripts/gates/m39y-transient-shaper-bytes.mjs` (which *"exits 3 THE GATE COULD NOT
TRUST"* its own inputs — :30 — and self-positive-controls, :83-84).

**Axis:** `kick.decay` ∈ {0.15, 0.35, 0.70, 1.40} s. One axis, four variants
(the house rule: 3–4 options differing on **one** axis).

**Assertions — physics, never bytes:**
1. Measured −60 dB decay of the final kick hit is **strictly increasing** across the four, and each
   within **±20%** of its set value.
2. Integrated LUFS constant within **1.5 LU** across all four (this is a *time* axis, not a volume
   axis — the transient-shaper gate's "it changed PUNCH, not VOLUME" shape, :205).
3. Measured fundamental within **±3%** of 52 Hz in all four (decay must not move pitch).
4. Byte-distinctness is asserted as a **floor only**, with the one-way-implication comment quoted
   inline (`render-variants.mjs:640-650`). A pass on distinctness alone is not a pass.
5. **Self-positive-control:** the gate synthesises a known 52 Hz tone with a known 0.7 s decay and
   runs its own measurement over it. If the measurement does not return 0.7 s ± 5%, **exit 3
   without scoring** — the `doc-count-drift` / m39y discipline. A measurement that cannot find a
   thing it knows is there must not be allowed to report an absence.

### 8.12 ⛔ Plants — and whether each can actually reach the output

The brief: *"a recent design shipped two plants that were multiplied by zero and could never have
fired."* Each row below states the **default that makes the plant reachable**, because that is the
half that was missing.

| # | Plant | Reaches output because | Must redden |
|---|---|---|---|
| P1 | Kick `pitchAmount` forced to 0 in the per-sample `f[n]` | default is **3.2 ≠ 0** | §8.1 zero-cross ratio (2.75 → 1.0) |
| P2 | Amplitude coefficient hard-coded to `T = 0.3 s` | default `decay` is **0.62 ≠ 0.3** | §8.1 decay row; §8.11 assertion 1 |
| P3 | Hat oscillator frequencies hard-coded (ignore `tune`) | ⚠️ **ONLY if the fixture uses `tune` ≠ 1.0.** At the default 1.0 the plant is invisible — this is the multiplied-by-zero trap. **The §8.3 fixture MUST render at `tune` 2.0.** | §8.3 tune-sweep row |
| P4 | Clap retrigger loop bounded to 1 pulse | default `spread` 0.011, 4 pulses | §8.5 local-maxima count (3+ → 1) |
| P5 | Snare noise level fixed at 0.5, ignoring `snap` | the §8.2 fixture sweeps `snap` 0→1 | §8.2 centroid monotonicity |
| P6 | Choke sweep removed | the §8.9 fixture plays OH then CH **inside** the OH tail | §8.9 rows 1–2 |
| P7 | Choke fade replaced by a hard cut | fixture as P6 | §8.9 row 2 (step threshold) only — row 1 still passes, which is the point |
| P8 | Velocity ignored (all hits at 127) | fixture **must** contain velocities 40 and 120 | velocity gate (§5) |
| P9 | `pan` ignored | fixture **must** pan ≥ 1 voice hard | stereo-image assertion |
| P10 | `PlaybackGraph.swift:1728-1737` — delete the `.drumSynth` cast branch | the live-graph test edits a param **mid-session** | §8.10 live-graph delivery test **only** — every construct-then-render test still passes. This plant proves the test is load-bearing. |
| P11 | `specs(for: .drumSynth)` returns `[]` | — | §8.10 spec-table test; `mod.addRoute` on `kick.tune` |
| P12 | Remove `drumKit` from `ProjectDocument.CodingKeys:914` | — | §8.10 persistence round-trip |
| P13 | Remove `drumKit:` from the `setInstrument` rebuild at `ProjectStore.swift:4022-4078` | — | §8.10 unrelated-edit test |
| P14 | Noise PRNG made free-running instead of position-seeded (§2.0) | — | a **suffix-identity** test: render [bar 5, bar 9] directly vs. slice it out of a [bar 1, bar 9] render, assert byte-identical. Nothing else catches this. |

**Every plant must be run and watched to redden before the gate is trusted** — and P3's entry is the
one to read twice.

---

## 9. Risks, and what is deliberately not being built

| Risk | Mitigation |
|---|---|
| ⛔ **Parameter edits silently undelivered** (`PlaybackGraph.swift:1728-1737`, Class C1) | §8.10 live-graph test + plant P10. **The highest-probability shipping defect in this item.** |
| ⛔ **The kit never persists** (`ProjectDocument.swift:914`, Class B7) | §8.10 round-trip over all 75 names + plant P12 |
| ⛔ **An unrelated knob edit deletes the kit** (`ProjectStore.swift:4022-4078`, Class B4) | Struct-mutation overlay (never an initialiser list) + §8.10 + plant P13 |
| ⛔ **Every modulation route silently dropped** (`ModulationSnapshotBuilder.swift:255`, Class C2) | §3.4's `spec.code` change + the polySynth positive control |
| **The `code` refactor silently renumbers live polySynth routes** | The §8.10 positive control asserting 0…6 are unmoved |
| **75 names blow the 64-route budget, silently** (`AutomationSchedule.swift:90-91` `.prefix`es) | `describeDrumKit` reports `routesUsed / routeBudget` (§7); §3.6 states the ceiling |
| **Hat aliasing corrupts its own test** | polyBLEP (§2.3) + the §8.3 foldover assertion |
| **Free-running noise breaks suffix identity** | Position-seeded PRNG (§2.0) + plant P14 |
| **Mono voices cut their own tails** | Accepted, hardware-faithful, documented; additive `voices` escape hatch named (§2.0) |
| **"Automatable" over-promised** | §3.6 states the limit plainly and files `m39-dm-lanes` |
| **The pad grid does not reach this instrument** | Deliberately wave item (4), not this one (§6) |

### Rejected alternatives, collected

| Rejected | Why |
|---|---|
| **Sampled kits instead of synthesis** | No parameters to expose or automate — it converts the item's premise into a gain knob. Zero drum content exists in the repo (`BundledSamples.swift:78-93`). Re-filed to wave item (3). §1 |
| **`pads: [DrumVoiceParams]` array** (the research doc's own proposal, `…synthesis-engines.md:528-531`) | An index is positional addressing; `InstrumentParams.swift:18-24` forbids it by name. Forces an `engine` enum per pad, which is discrete, which breaks "every parameter automatable" on knob one. §3.3 |
| **A new `AutomationTarget` case** | Widens the project's most persistence-sensitive enum (`Automation.swift:16-17`) and forks ~8 downstream switches, to buy structure a documented string grammar already provides. §3.3 |
| **75 optional args on `setInstrument`** | `ProjectStore.swift:3970-3976` + :4038-4058 document that every such argument must be hand-mirrored or it deletes itself. 75 is past human maintainability by construction. §7 |
| **A per-voice `character: .eightOhEight / .nineOhNine` enum** | 808 vs 909 differ in *numbers*, not topology, for every voice that both machines synthesise. The enum would be this instrument's only discrete parameter. Ships as presets instead. §2.1 |
| **A synthesised "909 hat"** | The 909's hats and cymbals are 6-bit PCM samples, not a circuit ([Attack Magazine](https://www.attackmagazine.com/features/interview/atsushi-hoshiai-the-man-behind-the-tr-909/)). A sample is what our sampler is for. Our hat is 808 lineage and says so. §2.3 |
| **A generic modal engine with per-voice mode tables** | Better *eventually* (`…synthesis-engines.md:278-280` names it as the upgrade path) but it turns 8 hand-tuned topologies into one data-driven one, which makes every parameter's meaning voice-dependent and every default a table. v1 hand-writes eight voices and uses the modal recursion only where a partial's frequency is fixed. §2.0 |
| **Polyphonic drum voices with stealing** | Introduces a discrete `voices` count and a stealing policy for a behaviour the hardware does not have. §2.0 |
| **Building instrument-param automation lanes inside this item** | A separate render-path piece, refused engine-wide today for every instrument (`ProjectStore.swift:3522-3537`). Filed as `m39-dm-lanes`, with the note that note-on latching makes it *cheaper* for this instrument than the general case. §3.6 |

---

## 10. Settles for `docs/ARCHITECTURE.md` — "Key future decisions"

⚠️ I was instructed not to edit any file but this one, so **the implementing agent makes these
edits.** Four decisions are settled here and should move out of "future decisions":

1. **Instrument parameter addressing is hierarchical by dotted name, never by index.**
   `<scope>.<param>` on `AutomationTarget.instrumentParam`. The effect side's append-only positional
   slot law (`Effects.swift:4218-4223`) **does not** extend to instruments and must never be allowed
   to (`InstrumentParams.swift:18-24`). Record it at architecture level so it is not re-litigated
   per instrument.
2. **`InstrumentParamSpec` carries its own render code.** The table is the single resolution point
   from name → render-thread identity; `InstrumentParamID(rawValue:)` is no longer a resolution
   step. The code is packed `(scope << 8) | param`, wire-local, never persisted.
3. **One-shot instruments latch every parameter at note-on.** `modulatable: .yes` +
   `appliesAtNextNoteOn: true` is the contract for percussive instruments, and it is why they need
   no per-sample or block-rate coefficient re-derivation. This is a *named class* of instrument in
   the architecture, not a property of one kind.
4. **Any render-path randomness must be seeded from the absolute sample position.** Free-running
   PRNG state breaks suffix identity and position-absolute determinism
   (`ModulationSnapshot.swift:27-33`). This generalises beyond drums and belongs in the RT-safety
   section next to "no allocation, no locks, no ObjC."

Also add to ARCHITECTURE's RT-safety notes: **adding an instrument kind touches 37 sites, 21 of them
not compiler-forced** — with the Class B/C/D taxonomy from §6, because the taxonomy is what makes
the next one cheap.

---

## 11. Implementation order — six steps, each independently testable

Route: **`audio-dsp-engineer`** for steps 1–3 (it fits inside the current render contract, as
`…synthesis-engines.md:551-553` recommends); **`swift-app-engineer`** for 4;
**`mcp-integration-engineer`** for 5; **`qa-test-engineer`** for 6.

| Step | Work | Files | Gate |
|---|---|---|---|
| **1** | `DrumKitParams` + `DrumVoiceParams` + every `…Range` constant + presets | `Sources/DAWCore/DrumKit.swift` (new) | Model round-trip; range clamping |
| **2** | `specs(for: .drumSynth)` — all 75 rows with `curve`, `modulatable`, `note`; **`code` AND `appliesAtNextNoteOn` moved into `InstrumentParamSpec`**; `currentValue` drum branch; `ModulationSnapshotBuilder:255` reads `spec.code` | `Sources/DAWCore/InstrumentParams.swift`, `Sources/DAWEngine/Modulation/ModulationSnapshotBuilder.swift` | **The polySynth 0…6 positive control** (§8.10). Nothing else may proceed until it is green. |
| **3** | `DrumSynthInstrument` — 8 voices, position-seeded noise, choke, velocity | `Sources/DAWEngine/Instruments/DrumSynthInstrument.swift` (new) | §8.1–8.9 physics tests + plants P1–P9, P14 |
| **4** | The 37 sites. **Class A first (the compiler drives them), then B, C, D from §6's table.** | 16 + 16 + 2 + 3 sites | §8.10's four structural tests + plants P10–P13 |
| **5** | Wire verbs + 4 MCP tools + `server.ts:2122` zod enum + docs | `Commands.swift`, `server.ts`, `SKILL.md`, `README.md` | `doc-count-drift.mjs` exit 0, both routes agreeing |
| **6** | Demo set + physics gate | `scripts/demos/specs/`, `scripts/gates/m39dm-drum-physics.mjs` | §8.11, including its own self-positive-control (exit 3 on an untrustworthy measurement) |

**Step 2's positive control is the gate on the whole item.** It is the only step that touches code
every existing modulation route already depends on.

---

## Appendix — what I could not verify

- **Nothing was built or run.** Two other agents held the tree; no `swift build` / `swift test` /
  `./scripts/test.sh` was executed. Every claim is from reading source, and every file:line was read
  in this session.
- **UNVERIFIED — snare partial frequencies.** 180 Hz / ratio 1.83 are common software practice, not
  a circuit-sourced figure. The "two drumhead modes" *architecture* is sourced (McGill). The numbers
  are parameters; nothing structural depends on them.
- **UNVERIFIED — clap bandpass centre (~1000 Hz).** The four-pulse / 11 ms structure **is** sourced;
  the band centre is not.
- **UNVERIFIED — 808 kick component values.** I model the standard software decomposition the
  research doc itself cites, not the bridged-T circuit directly.
- **PARTIALLY VERIFIED — the six 808 hat frequencies.** Sourced as a set from Baratatronix, but the
  same search surfaced Tiptop Audio measurements showing real units vary by up to ~20% and that only
  the 800/540 Hz oscillators are tunable in-circuit. The set is right; the digits are nominal.
- **UNVERIFIED — that `DrumSynthInstrument`'s per-sample cost fits the render budget.** It looks
  comfortable (8 mono one-shot voices; the hat/cymbal banks are 6 polyBLEP squares each, and only
  while sounding) but I did not measure and **no existing measurement covers it**. Step 3 should
  measure before step 4 begins.
- **UNVERIFIED — whether the pad grid can host a non-sampler instrument without further change.**
  `PadGridModel.swift:222-223` says its zones are empty for any non-sampler track; I did not trace
  every consumer. It is wave item (4) regardless.
- **Site count caveat.** 37 sites is what a trace of `.soundBank` and `.sampler` across `Sources/`
  plus `server.ts` found. It is a **floor, not a proof of completeness** — an unforced site that
  names neither kind (a `default:` clause somewhere I did not grep) would not appear. The three
  compiler-forced classes are complete by construction once the build is green; Class B/C/D are not,
  and step 4 should re-run the trace against `.drumSynth` itself after landing.
