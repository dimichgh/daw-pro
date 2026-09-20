# Plugin programme — measured inventory and cost base

**Date:** 2026-09-19
**Measured by:** orchestrator (main context), directly, on a quiescent tree at branch `m23-wip-2026-08-10`.
**Purpose:** the factual base for the "build our own instruments and effects" programme. Every
number here was measured today by the person writing it down. Figures carried in from memory are
marked with the date they were last measured and are **not** treated as current.

This document is deliberately separate from the five domain research reports written by
`research-analyst` agents on the same date (`2026-09-19-synthesis-engines.md`,
`-dj-loop-fx.md`, `-reverb-delay-space.md`, `-modulation-macros.md`, `-dynamics-character.md`).
Those say what the industry does. **This one says what we have and what a change costs.**

---

## 1. What we ship today

### 1.1 Effects — 11 built-in kinds, 64 parameters total

Counted off the `EffectKind` enum in `Sources/DAWCore/Effects.swift` and the per-effect
`CodingKeys` (the persisted parameter surface).

| Kind | Params | Parameter names |
|---|---:|---|
| `gain` | 2 | `gainLinear`, `invertPolarity` |
| `eq` | 22 | 4 bands (2 shelves + 2 peaks) with freq/gain/Q/enable each, plus HP/LP with freq/slope/enable |
| `compressor` | 7 | `thresholdDb`, `ratio`, `attackMs`, `releaseMs`, `kneeDb`, `makeupDb`, `mix` |
| `limiter` | 3 | `ceilingDb`, `releaseMs`, `truePeak` |
| `reverb` | 5 | `roomSize`, `damping`, `mix`, `preDelayMs`, `width` |
| `delay` | 7 | `timeMs`, `feedback`, `mix`, `pingPong`, `highCutHz`, `sync`, `division` |
| `saturator` | 3 | `driveDb`, `mix`, `outputDb` |
| `gate` | 4 | `thresholdDb`, `attackMs`, `holdMs`, `releaseMs` |
| `chorus` | 3 | `rateHz`, `depthMs`, `mix` |
| `bassEnhancer` | 3 | `crossoverHz`, `amount`, `mix` |
| `bitCrusher` | 5 | `bits`, `downsampleHz`, `antiAlias`, `dither`, `mix` |
| `audioUnit` | — | hosted third-party AU (opaque) |

**The shape of the gap is the point, not the count.** Every one of these is a *corrective* or
*mixing* tool. There is not one *performance* or *creative* effect in the list: no filter sweep,
no gater, no beat repeat, no tape stop, no phaser, no flanger, no frequency shifter, no transient
shaper, no shimmer, no stereo widener, no multiband anything.

### 1.2 Instruments — 4 kinds, and only one of them is ours in any real sense

`InstrumentKind` (`Sources/DAWCore/Model.swift:1603`): `polySynth`, `sampler`, `audioUnit`,
`soundBank`.

- **`sampler`** — genuinely deep. `SamplerInstrument.swift` is 133 KB; zones, keymaps, varispeed,
  round-robin, mono choke, glide/legato (m34-t). This is our real instrument.
- **`soundBank`** — SF2/DLS playback. Content, not synthesis.
- **`audioUnit`** — someone else's plugin.
- **`polySynth`** — ours, and it is a test tone with a filter on it. Full surface below.

### 1.3 The entire PolySynth parameter surface

From `PolySynthParams` (`Sources/DAWCore/Model.swift:2545-2616`). This is not an excerpt — it is
every parameter the instrument has.

| Parameter | Range | Unit |
|---|---|---|
| `waveform` | saw · square · triangle · sine | — |
| `attack` | 0.0005 – 5 | s |
| `decay` | 0.001 – 5 | s |
| `sustain` | 0 – 1 | level |
| `release` | 0.001 – 8 | s |
| `cutoffHz` | 40 – 18 000 | Hz |
| `resonance` | 0 – 1 | — |
| `gain` | 0 – 1 | — |
| `pedalHoldLimit` | 1 – 128 (optional, nil = unlimited) | notes |

One oscillator, one envelope hardwired to amplitude, one lowpass filter, one gain. No sub
oscillator, no noise source, no unison or detune, no filter envelope, no velocity routing beyond
amplitude, no FM, no wavetable, no drift.

### 1.4 Modulation — there is none, anywhere

No LFO, no envelope follower, no step sequencer, no macro, no modulation matrix exists anywhere in
`Sources/`. The only time-varying control a user has is a hand-drawn automation lane.

✅ **CONFIRMED 2026-09-19 by a dedicated survey, with a positive control.** `envelopeFollower` and
`modMatrix` return zero hits anywhere in `Sources/`. The only `LFO` hits are inside
`ChorusEffect.swift`, describing that effect's own internal fixed sine oscillator which modulates
its two delay taps — it has no output any other parameter can read and is not a source. Every
`modulation` hit is either MIDI-CC amplitude/brightness routing, an unrelated musical key-change
sense, or a named-but-unbuilt future UI surface. Every `macro` hit is unrelated (SFZ `#define`,
Swift compiler terminology, the `macro-a/b/c` milestone naming convention, spectral "macro bands").

Positive control: the same grep shape returns 106 hits for `compressor` and correctly finds the
chorus LFO. So this is searched-and-absent, not a broken pattern.

---

## 2. Presets — measured absence, with a positive control

The user's framing was that our plugins "do not yet expose their parameters and presets". Half of
that is already solved and half is a real hole:

- **Parameters ARE exposed.** `au.describeParams` / `au.setParam` for hosted AUs
  (`Sources/DAWControl/Commands.swift:7808, 7861`); `fx.describe` / `fx.setParam` for built-ins.
- **Presets are NOT, and nothing ever tried.**

```
factoryPresets      0 matches   across all of Sources/
currentPreset       0 matches
AUAudioUnitPreset   0 matches
──── positive control, same command shape ────
AUAudioUnit        10 files     ← the search was working
```

The positive control matters: in this tree a tool that never ran and a tool that ran and found
nothing produce identical output. The control proves this is an absence, not a broken pattern.

**This was already filed.** `m23-cw` (`docs/ROADMAP.md:1076`, filed 2026-08-04) describes exactly
this gap and independently confirms it: *"there is no `*.preset*` wire verb at all, and all 16
'preset' hits across `Sources/DAWControl` are `mixer.applyPreset`, which is a MIXER-CHANNEL preset
and unrelated."* Its route line — `audio-dsp-engineer`, wire by `mcp-integration-engineer` — is the
route being used.

---

## 3. What a new plugin actually costs

Measured empirically by taking the footprint of the most recently added kind on each side
(`bitCrusher` for effects, `polySynth` for instruments) rather than by estimating.

| | Exhaustive `switch` sites (**mandatory edits**) | Files mentioning the kind (**blast radius**) |
|---|---:|---:|
| New **effect** kind | **6** | 29 |
| New **instrument** kind | **8** | 84 |

**The two columns mean different things and must not be conflated.** The switch-site count is the
set of places the compiler will force you to edit — the irreducible cost. The blast radius includes
tests that merely use the kind as a fixture, docs that mention it, and dogfood logs; most of those
need no change for a *new* sibling kind.

Effect switch sites: `EffectFactory.swift`, `EffectEditorModel.swift`, `MixerModel.swift`,
`Effects.swift`, `ProjectStore.swift`, `Commands.swift`.

Instrument switch sites: `PlaybackGraph.swift`, `InstrumentPickerModel.swift`,
`ProjectStore+TimbreLiveness.swift`, `MIDIControllerRouting.swift`,
`InstrumentControllerSupport.swift`, `ViewUIWireSurface.swift`, `InstrumentPickerView.swift`,
`InstrumentChip.swift`.

Beyond the switch sites, each new kind also needs: the DSP itself, a UI editor surface, a control
command, an MCP tool, tests on both sides, and docs — the standing "every capability ships a control
command, an MCP tool, and a test" rule.

### 3.1 The design consequence

A new **instrument kind** costs meaningfully more than a new **effect kind**, and the instrument
cost is concentrated in UI and routing rather than DSP. If the programme ships three synthesis
engines, adding three `InstrumentKind` cases pays that 8-site bill three times.

**Hypothesis for the architecture pass to settle (not adopted here):** add **one** new instrument
kind whose parameters select the engine, rather than one kind per engine. That pays the routing and
picker cost once and turns "add an FM engine" into a DSP-and-params change. The counter-argument is
that the picker, the editor UI and the preset catalogue all want to present three distinct
instruments to the user, and a single kind with a mode switch can make that awkward. This is exactly
the kind of call `daw-architect` should make with the research in hand.

---

## 3.2 Constraints any new parameter or modulation system inherits

Measured by the capability survey, 2026-09-19, each with a file:line anchor. **These are not style
preferences — each one will silently break a design that ignores it.**

### ⚠️ Automation slots are POSITIONAL, and the ordering is load-bearing

The render thread stores an automated value by **slot index**, not by name:
`storeAutomatedParam(slot: Int, value: Double)` (`Sources/DAWEngine/Effects/EffectRendering.swift:66`),
where `slot` is the index into `EffectParamSpec.specs(for: kind)`. Every built-in effect's param
list carries repeated comments that a new param was *"APPENDED so the automation slot indices never
move"* (`Sources/DAWCore/Effects.swift:972-974`, `:1013-1014`, `:1075-1076`).

**Consequence:** parameter lists are append-only forever. Inserting a parameter in the middle of an
existing effect's spec array silently re-points every saved automation lane on that effect to the
wrong parameter. A new plugin's parameter surface should be designed with this in mind from the
first commit, because it cannot be reordered afterwards.

### `EffectParamSpec` carries less than an LLM needs

The whole struct (`Sources/DAWCore/Effects.swift:929-947`) is: `name`, `range: ClosedRange<Double>`,
`defaultValue`, `unit: String` (free text — "dB", "Hz", "s", "ratio", "%"), and an optional free-text
`note`. There is **no curve/taper field** (a 40–18 000 Hz cutoff is a plain linear range with no
log-taper hint, so an agent setting it to the midpoint gets 9 kHz, not the musical middle) and **no
group field** (UI sectioning is hardcoded client-side). Params are a flat array whose position is
the automation slot.

Extending this struct is probably the single highest-leverage change in the programme: it is what
both the UI and every AI agent read to understand a parameter.

**And the taper semantics already exist — they are just in the wrong place, twice.** Measured
2026-09-19: the log-taper mapping is implemented independently in
`Sources/DAWAppKit/EffectEditorModel.swift:458,470` and again in
`Sources/DAWAppKit/PolySynthEditorModel.swift:287,299`, in both cases *inferred from the free-text
unit string* — the comment at `PolySynthEditorModel.swift:268` states the rule outright: *"only
Hz-unit params get the log taper."*

So a knob in our UI knows that cutoff is logarithmic, and an AI agent driving the same parameter
over the wire does not, because the wire carries only name/range/unit/note. Three problems in one:
duplicated logic, a string-matching heuristic standing in for a declared property, and a UI that is
strictly better informed than the agent. Lifting `curve` into `EffectParamSpec` fixes all three and
gives the parameter surface **one home**, which is the pattern this codebase already prefers.

### The good precedent: `fx.setParam` addresses by NAME

Effect parameters are set by string name with clamp-and-warn semantics — out-of-range values clamp
and the response names what was asked versus what was stored
(`Sources/DAWControl/Commands.swift:2440-2478`), and `fx.describe` returns the full spec table
(`:2534-2570`). **Any new plugin surface should imitate this**, not the opaque-decimal-address model
that hosted AUs are stuck with.

### Tempo sync: the math is general, the plumbing is not

`NoteDivision` (18 cases — whole through thirty-second, each straight/dotted/triplet) and
`milliseconds(atBPM:)` live in `Sources/DAWCore/TempoMap.swift:266-315` and are reusable. But the
resolver that substitutes a synced time before it reaches the render thread is hardwired:
`guard effect.kind == .delay` (`Sources/DAWCore/DelayTempoSync.swift:36-37`). A new tempo-synced
effect gets the math free and the plumbing not at all — it must be wired into five intake seams
(`OfflineRenderer.swift:272,274`; `AudioEngine.swift:1105`, `:2374`, `:3925-3932`) and must add its
own refusal to `Automation.swift:90-97`, which currently names `.delay` explicitly to stop a lane
being drawn on a `sync`/`division` param. **Generalising this resolver is a prerequisite for any
tempo-synced creative effect**, and doing it once is much cheaper than doing it per effect.

### Sidechain: routing is reusable, but there is no control-signal abstraction

`SidechainGraph` (`Sources/DAWCore/Sidechain.swift:17-97`), `ChainHostAU`'s bus-1 key input, and the
`KeyableEffectRendering` protocol (`Sources/DAWEngine/Effects/EffectRendering.swift:86`) form a
genuinely reusable render-thread seam — the chain walk hands the pulled key buffer to any armed unit
that conforms. But only `CompressorEffect` and `GateEffect` adopt it, the store hard-gates
destinations to those two kinds (`ProjectStore.swift:3414-3415`), and **the key is always a raw audio
buffer consumed by a detector inside one effect — there is no exposed envelope value that a
modulation source could read.** An envelope follower is therefore new work, but it has good
scaffolding to stand on.

### Automation cannot reach instruments at all

`AutomationTarget` (`Sources/DAWCore/Automation.swift:18-27`) has exactly four cases: `.volume`,
`.pan`, `.sendLevel`, `.effectParam`. `.effectParam` resolves strictly against `track.effects`
(`:86-101`); there is no code path from any automation target to `track.instrument`. Curves are
`linear` or `hold` only — no bezier. **So today a filter sweep on a synth is impossible**, which is
worth stating plainly: it is the most basic gesture in electronic music and our product cannot do it.

### One cheap, obvious gap found in passing

Effects have `fx.describe` and the sampler has `instrument.describeSampler`
(`Sources/DAWControl/Commands.swift:1772`). **PolySynth has no describe verb at all** — an agent
cannot ask the running app what the synth's legal ranges and units are; they exist only as static
Swift constants and as prose baked into `server.ts`. Small, self-contained, and directly in the
programme's "make our own plugins legible to an agent" thesis.

---

## 4. Prior art in this tree — items already filed, do not duplicate

Several gaps the programme would "discover" were already found and written up by earlier audits.
The milestone must **adopt these IDs**, not mint new ones beside them. (Precedent: `m27-n`
duplicated `m26-a` and had to be merged.)

| ID | Gap | Notes carried by the item |
|---|---|---|
| `m23-cw` | No way to browse or load an AU's own factory/user presets | **In flight 2026-09-19.** Carries the constraint that live plugin state lives in `AUHostRegistry`, never in the model — writing `stateData` into the model reintroduces a stale-state bug that cost eight cycles. |
| `m23-cl` | No multiband compressor or dynamic EQ | Called "the best-evidenced competitor gap in the audit" (all five compared DAWs have one). **Requires a design spike before build commitment** — crossover topology and band count are render-thread shape decisions. Weight L. |
| `m23-dj` | No mono→stereo widening of any kind | User asked for *"true stereo"*, not a Haas/polarity trick. Item specifies three honest approaches and makes **mono compatibility the acceptance test**, not a nice-to-have. Weight M. |
| `m23-ci` | No dither on bit-depth-reduced export | Adjacent — our `bitCrusher` has a `dither` param but the exporter does not. |
| `m23-m4` | Export presets — **deferred, with an argument that bears on this programme** | See §4.1. |

### 4.1 The standing counter-argument about presets

`m23-m4` deferred export presets on an explicit rationale: *"this app is MCP-native, so an agent
already gets 'preset' behaviour for free by remembering a param set, which is not true of the four
surveyed DAWs where a preset is the only way to avoid re-typing a dialog."*

That argument is sound **for an export dialog** and should be respected there. It is weaker for
instruments, for two reasons worth stating plainly so the decision is made and not drifted into:

1. An instrument preset is not a remembered dialog — it is a *curated sound*, authored by someone
   who knows the engine. "Remember these 40 numbers" does not produce a good supersaw; knowing which
   40 numbers make one does.
2. `m23-cw` makes the opposite case for the same reason, in its own words: *"an agent can tune a
   patch but cannot START from one. Every real instrument's usable sound space is reached through
   its preset list — asking an agent to dial a supersaw from a default patch parameter-by-parameter
   is the expensive path to a worse result."*

So the two filed items disagree in emphasis, and the resolution is that **the MCP-native argument
scales with how well the parameters describe themselves**. That is itself an argument for making
our own plugin parameters semantic, named and unit-bearing from the start.

---

## 5. Figures carried in from memory — last measured, not re-measured today

Recorded so they are not mistaken for today's measurements.

- MCP tool count **220**, wire command count **215** — last measured 2026-09-04.
- Swift suite **7924 tests / 709 suites**, wall ~273 s — last measured 2026-09-04.
- `node scripts/gates/doc-count-drift.mjs` is the command-count pin; it derives the total two
  independent ways and self-positive-controls.
- Apple's 23 built-in AU effects all enumerate and load in 1–6 ms (measured 2026-08-13). Third-party
  AUv2 (Surge XT) wedges the main actor for minutes — never use one as a test fixture.

**These must be re-measured before the milestone closes.** A net delta can hide a shrink, so any
agent reporting a test-count change must NAME what it retired.

---

## 5.1 Pre-registered architectural hypothesis (orchestrator, before research landed)

Written down **before** the five domain research reports and the `daw-architect` pass returned, so
that agreement can be recognised as corroboration rather than manufactured by hindsight. If the
research contradicts any of this, the research wins and this section stays as the record of what I
expected.

**H1 — Modulation should ride the automation value-delivery path that already exists.**
Automation already computes one value per parameter per block on the render thread and delivers it
via `storeAutomatedParam(slot:value:)`. A modulator is simply another *producer* of that same
per-block value. So the render-thread integration point is already built, proven and RT-safe — the
new work is the source (LFO/follower/step-seq) and the routing, not the delivery. **Predicted
consequence:** a modulation layer is meaningfully cheaper than its reputation, in the same way M32
"halved on measurement".

**H2 — Route per-parameter, not through a fixed matrix.**
Each target parameter carries a list of modulators with depths (the Serum/Vital/Bitwig model),
rather than a fixed N×M matrix. Reason: it matches the existing name-addressed
`AutomationTarget.effectParam(effectID:paramName:)` domain model exactly, it has no arbitrary size
limit, and it maps cleanly onto a wire command an agent can write in one line
(`mod.add {target:{effectId, paramName}, source:{lfo, rate:"1/8"}, depth:0.4}`).

**H3 — Extending `AutomationTarget` to reach instruments buys two features for one change.**
Today automation cannot target `track.instrument` at all, which is why a filter sweep on a synth is
impossible. Modulation wants exactly the same reach. Adding an instrument case to the target enum
therefore unblocks *both* hand-drawn automation of a synth and modulation of a synth, from one
edit. **This is likely the highest value-per-unit-of-work item in the entire programme.**

**H4 — Generalise the tempo-sync resolver once, before any synced effect is built.**
`DelayTempoSync` is hardwired to `.delay` across five intake seams. Every tempo-synced creative
effect and every synced LFO needs that resolution. Doing it once is much cheaper than per-effect,
and doing it *after* two synced effects ship means retrofitting both.

**H5 — `EffectParamSpec` gains `curve` before any new plugin ships, not after.**
Parameter arrays are append-only forever because position is the automation slot. Metadata *fields*
can be added safely; parameter *entries* cannot be reordered. So the spec struct should be enriched
while the number of effects is still 11.

**What would falsify these:** if per-block modulation resolution proves audibly too coarse (zipper
noise or stepped LFOs at high rates), H1 is wrong and modulation needs its own per-sample or
smoothed path independent of the automation store. That is the single most important thing for the
architecture pass to measure rather than assume.

### ⭐ H1 tested against measured evidence the same day — PARTIALLY FALSIFIED

I went looking for that falsifier immediately and the codebase had already measured it.
`Sources/DAWCore/RenderBlockSize.swift` is an unusually complete piece of prior work and it answers
the resolution question outright.

**The offline render block is 512 frames**, which makes the block-rate modulation sampler
**93.75 Hz at 48 kHz, with a Nyquist of 46.875 Hz** (`RenderBlockSize.modulationSamplingHz`). This
number was not chosen — it was measured into place by m28-bug. At the previous 4096 frames the
sampler ran at 11.719 Hz with a 5.86 Hz Nyquist, *underneath the entire musical modulation band*,
and the documented consequence was not a shallower vibrato but a **different** one: alias images at
`|f_s − f|`, several louder than the fundamental. A commanded ±50 ¢ 11 Hz vibrato bounced as ±49.8 ¢
**at 0.72 Hz**; a commanded 11.72 Hz vibrato bounced as a **static −17.9 ¢ detune**. At 512 frames
all three test rates deliver correctly with small residual images, attenuated ~7×. Measured cost:
**1.31× bounce time**, accepted.

**What this does to H1:**

- ✅ **Confirmed for smooth modulation.** 46.875 Hz of Nyquist clears the whole musical modulation
  band, so LFO-on-filter, LFO-on-amplitude, vibrato and tremolo ride the existing per-block path
  correctly. The cheap-modulation prediction holds for this class.
- ⚠️ **At risk for sharp rhythmic modulation.** A trance gate or beat repeat needs *edges*, not a
  band-limited waveform. At 93.75 Hz the edge position quantises to ~10.7 ms. A 1/16 note at
  128 BPM is 117 ms, so edges land with up to ~9 % slop and — worse — *inconsistent* slop, because
  the error depends on where the edge falls within a block. Gating will sound soft and slightly
  unsteady. **A square-wave LFO on the per-block path is not good enough for the thing the DJ/loop
  wave most wants.**
- 🚨 **A correctness problem nobody has measured: live and offline modulation rates differ.** The
  512-frame figure is the *offline* pull size. The live block is the hardware buffer, which the file
  states plainly is "device-dependent and user-changeable, and live playback has never been measured
  here." So a tempo-synced gater could audibly differ between monitoring and bouncing — the class of
  defect that ships silently and is found on someone else's machine. **This must be measured before
  any tempo-synced creative effect ships**, and it is exactly the kind of "the record says X, the
  source says Y, and nothing compares them" failure this tree is prone to.

**Revised position:** modulation sources split into two tiers rather than one.
*Smooth* modulators (LFO for filter/amp/pitch, envelope follower, macro) ride the existing per-block
path and are genuinely cheap, as H1 predicted. *Rhythmic* modulators (gate patterns, step
sequencers, beat repeat) need sample-accurate edge scheduling — the same problem the MIDI scheduler
already solves for note events, which is where the solution should be borrowed from rather than
invented.

**Reusable precedent found alongside it:** `EffortField.hostedAUOfflineModulationSamplingHz` already
drives *user-facing capability warnings* when an authored modulation rate exceeds what the block rate
can carry. The modulation layer should reuse that pattern — if an agent asks for a 30 Hz LFO on a
hosted AU, the honest answer is a warning, not a silently aliased result.

---

## 6. Open questions routed to the user

Published as a handoff artifact on 2026-09-19 rather than blocking the run: ship in waves vs one
release; modulation layer first vs creative effects first; which synthesis engines are actually
wanted; and who may author a preset. Each has a default already being proceeded on.

## 7. Agent claims I re-verified myself (standing rule: verify, do not trust the report)

Research agents produce claims; this section records the ones I checked against the source
personally, so downstream design work can treat them as measured rather than as reported.

### ⭐ VERIFIED — the reverb's `roomSize` does not control size

Claimed by `docs/research/2026-09-19-reverb-delay-space.md`. **Confirmed by reading
`Sources/DAWEngine/Effects/ReverbEffect.swift` on 2026-09-19:**

- `:213` — `combFeedback = Float(0.7 + 0.28 * p.roomSize)`. This is the *only* place `roomSize`
  reaches the DSP. It scales comb **feedback**.
- `:29-30` — comb and allpass lengths are fixed constants (`1116, 1188, 1277, 1356, 1422, 1491,
  1557, 1617` / `556, 441, 341, 225` — the classic Freeverb tunings).
- `:135` / `:151` — those constants ARE multiplied by a `scale` factor, which is why this needed
  checking rather than assuming. **`:127` — `let scale = sampleRate / 44_100.0`.** It is
  sample-rate normalisation, computed once in `prepare()`, and has nothing to do with `roomSize`.

⭐ **The `scale` factor is the reason to record this as verified.** A reader grepping only for
`roomSize` sees fixed tunings and concludes "no size control"; a reader who notices `scale`
sees lengths being modulated and could conclude the opposite. Both greps are correct and one
conclusion is wrong. Only reading `:127` settles it.

**So: `roomSize` is a mislabeled RT60/decay control.** There is no independent size parameter, no
frequency-dependent decay, and no tail modulation — the last being the textbook cause of metallic
ringing.

⛔ **The fix is NOT a rename.** Wire and parameter names are additive-only and never renamed, and
`.reverb`'s automation slots are positional (§3.2), so `roomSize` is frozen at slot 0 forever.
A real size control has to arrive as a **new additive effect kind** alongside `.reverb`, which is
what the reverb report recommends (an FDN). Until that ships, the honest move is to describe the
parameter accurately in `fx.describe`/MCP prose rather than to pretend it sizes a room.

### ⚠️ Citation imprecision in the same report — corrected here

That report cites the file as `ReverbEffect.swift`; the real path is
`Sources/DAWEngine/Effects/ReverbEffect.swift` (the `Effects/` subdirectory is omitted
throughout). The findings reproduce at the corrected path; the line numbers are accurate. Noting
it because a constructed-and-unverified path is exactly how a false "this file has no writers"
finding was once recorded in this tree.

### ⭐⭐ VERIFIED — the interpolated modulated delay line ALREADY EXISTS, in `ChorusEffect`

The single most cost-reducing finding of the reverb/delay report, so I checked it myself.
`Sources/DAWEngine/Effects/ChorusEffect.swift`:

- `:7` — doc: taps are "read with LINEAR interpolation from one shared line per channel".
- `:131-143` — the tap itself: `let fraction = Float(delay - Double(whole))` … `return s0 + (s1 - s0) * fraction`.
- `:104` — the line is already sized for "center + MAX depth (25 ms) + interpolation/rounding",
  i.e. the capacity headroom an interpolated read needs is already reasoned about here.
- `:12` — it already guarantees "the interpolated read never crosses the write head", which is the
  subtle correctness condition a fresh implementation would most likely get wrong.

**This one primitive is what three separately-requested features each need:** anti-metallic reverb
tail modulation, tape wow/flutter, and BBD pitch wobble. Lifting it into a shared RT-safe
`InterpolatedDelayLine` is strictly cheaper than writing any one of them from scratch, and the
write-head-crossing guarantee is already paid for.

⚠️ **But do not "lift" it carelessly.** The ONE-HOME law in this tree cuts both ways: a shared home
*narrower than its callers* does not prevent divergence, it causes it. A reverb tail modulator and a
tape wow have different depth/rate ranges and different capacity needs; widen the extracted home
deliberately, with the safe behaviour as the default, rather than normalising the chorus's current
constants into it.

### ⭐ VERIFIED — `DelayEffect` is integer-sample-only, so it structurally cannot wow or flutter

`Sources/DAWEngine/Effects/DelayEffect.swift`:

- `:45` — `private var delaySamples = 16_800` — an **`Int`**.
- `:144-145` — set by `Int((p.timeMs * 0.001 * sampleRate).rounded())`; the fractional part of the
  requested time is discarded at assignment.
- `:209-212` — the read is plain integer indexing: `var readIndex = index - delaySamples` …
  `line[readIndex]`. No fractional tap anywhere.

So smooth delay-time movement is not a tuning problem in the current delay, it is a structural
one — any time change snaps to a whole sample, which is also why click-free time modulation is
impossible today. This is the concrete justification for a new additive tape/BBD delay kind rather
than adding parameters to `.delay`.

### ⚠️ PARTIALLY VERIFIED, AND RE-FRAMED — "ducked reverb is almost free" asks the wrong question

The reverb report proposes extending the sidechain effect-kind whitelist so reverb/delay can duck.
The whitelist is real — `Sources/DAWCore/ProjectStore.swift:3414`:

```swift
guard kind == .compressor || kind == .gate else {
    throw ProjectError.sidechainUnsupportedEffect(kind)
}
```

**But widening that guard is one line, and it buys nothing on its own.** The guard is not what makes
ducking work; the *effect's DSP* has to read the key signal and apply gain reduction, and neither
`ReverbEffect` nor `DelayEffect` has any such path. So the honest cost is "one line + a real
ducking implementation in each effect," not "almost free."

⭐ **The more useful observation: this may already be achievable today, with zero new code.** The
standard studio technique for ducked reverb is not a ducking reverb — it is a reverb on a bus with a
**sidechained compressor after it**. Our existing constraints appear to permit exactly that:

- the destination strip must be `.audio` or `.bus` (`:3421`) — a reverb send bus **is** `.bus`;
- the source may be any non-bus track (`:3427`) — a kick on an instrument or audio track qualifies;
- `.compressor` is already whitelisted.

⛔ **This is a HYPOTHESIS, not a finding — I have read the guards, I have not rendered it.** It is
recorded here so the question asked next is the right one. **Test it before building anything:**
build kick + reverb-bus + sidechained compressor, render, and measure whether the reverb tail
actually pumps against the kick. Use a positive control — the same render with the sidechain
cleared — because "the tail got quieter" and "I measured nothing" look identical in a spectrum.

If it works, the gap is **documentation and a preset**, not DSP, and the whole item collapses from
an effect rewrite to a `mixer.applyPreset` entry plus prose an agent can discover. If it does not
work, the render will say *why*, and that reason is the actual specification for the fix. Either
outcome is cheaper than widening the guard on the assumption that ducking exists behind it.

⚠️ This is the same shape as M32, where the engine turned out to be **already mostly capable** and
the milestone halved on measurement. Measure first.

### ⭐⭐ VERIFIED AND STRENGTHENED — the "mix assistant" DSP is not just built, it is already ON THE WIRE

`docs/research/2026-09-19-dynamics-character.md` argues an Ozone/Neutron-class assistant is "nearly
free" because the analysis DSP already exists. All four primitives are real:

| claimed | actual path |
|---|---|
| `Loudness` | `Sources/DAWCore/Loudness.swift` |
| `MasterMixAnalyzer` | `Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift` |
| `ReferenceAnalyzer` | `Sources/DAWEngine/Analysis/ReferenceAnalyzer.swift` |
| per-insert spectrum tap | `Sources/DAWControl/InsertSpectrumLeases.swift` |

⭐ **The report understates its own case.** These are not merely implemented — they are **already
exposed as MCP tools today**: `mixer_master_analysis`, `mixer_live_loudness`,
`render_measure_loudness`, `reference_analyze`, `reference_compare`, `frequency_reference`, and
`fx_spectrum`. An agent can already measure loudness, true peak, tonal balance, per-insert
spectrum, and A/B against a reference track, **without one line of new DSP or wire work.**

So the gap is not capability. It is that nothing *synthesises* those readings into a diagnosis, and
an agent must currently know which seven tools to call and how to interpret them. The report's
sharpest point stands: unlike Ozone/Neutron we need no auto-apply black box, because the calling
agent already holds `fx.*` write access — the assistant only has to say what is wrong, not do it.

⚠️ **Scope flag, recorded so it does not quietly displace the brief.** The user asked for
*instruments and effects with parameters and presets*. A mix assistant is adjacent to that, not an
instance of it. It is plausibly the highest value-per-token item surfaced by any of the five
reports, and it is the most directly "AI-native" thing in the programme — but it should be offered
as an option, not substituted for the plugin work that was actually requested. Filed, recommended,
and deliberately NOT promoted ahead of the instruments and effects.

### ⭐ VERIFIED — a transient shaper genuinely cannot reuse `TransientAnalyzer`

`Sources/DAWEngine/Analysis/TransientAnalyzer.swift:24-25`, verbatim:

> `REAL-TIME SAFETY: this type is never referenced from the render path. It allocates and does file
> I/O freely because it only ever runs inside a …`

and `:6` / the type doc confirm it is an **offline, file-in** spectral-flux onset detector for
comping/quantise. It is not a candidate for the render path under any refactor short of a rewrite.
The report's claim that a transient shaper needs a genuinely new RT-safe two-envelope-follower
detector is therefore **correct, and is the real cost of that feature** — not the gain stage, which
is trivial. Anyone scoping the transient shaper should price the detector, not the shaper.

## 8. The modulation report's reuse claims, verified — two carry corrections that change the design

`docs/research/2026-09-19-modulation-macros.md` costs Tier B ("step sequencer / trance gate need
sample-accurate events") as cheap, because it can be assembled from parts that already exist.
I checked all four parts. **All four are real. Two are not shaped the way the design assumes.**

⚠️ Method note: my first grep for two of these returned empty — because I had **constructed** the
paths (`Sources/DAWCore/MIDISchedule.swift`, `Sources/DAWCore/AutomationSchedule.swift`) and both
actually live under `Sources/DAWEngine/`. An empty grep on a guessed path is the precise shape of a
false "this does not exist" finding this tree has been burned by before. The real paths are
`Sources/DAWEngine/MIDISchedule.swift` and `Sources/DAWEngine/Automation/AutomationSchedule.swift`.

### ✅ VERIFIED as claimed

- **`EffortField.modulationImageRatio(rateHz:samplingHz:)`** — `Sources/DAWCore/EffortField.swift:1061`,
  with `hostedAUOfflineModulationSamplingHz` at `:1029` and the closed-form inverse
  `f = f_s · r / (1 + r)` documented at `:1069`. The alias-warning machinery Tier A wants to
  generalise genuinely exists and is already closed-form.
- **`AutomationSchedule.value(at:)`** — `Sources/DAWEngine/Automation/AutomationSchedule.swift:396`:
  `static func value(at t: Int64, points: UnsafeBufferPointer<AutomationBreakpoint>, …)`. An
  arbitrary-time evaluator over a raw buffer pointer — already the RT-safe shape, no Array
  machinery. Reusable as claimed.

### ⛔⛔ CORRECTION 1 — `ScheduledMIDIEvent` is a FULL 24-byte POD with no room for a modulation value

> ❌ **THIS SUBSECTION IS PARTLY WRONG — SEE §10 BEFORE ACTING ON IT.** The "8-bit resolution"
> claim below is **retracted**: kind 3 already spans both `UInt8`s for 14-bit, so a kind-5 event
> gets 16,384 steps. The `noteID`-is-free claim is also retracted. **The per-instrument-track
> scoping wall is the part that survives**, and it is the real discriminator.

`Sources/DAWEngine/MIDISchedule.swift:14-26`. The struct carries `sampleTime: Int64` (so it is
sample-accurate as claimed — by absolute sample time, not a per-block offset), plus `noteID: UInt64`,
`kind: UInt8`, `pitch: UInt8`, `velocity: UInt8`. Its own header says, verbatim:

> `No POD size change — 24 bytes stays 24 bytes; consumers that switch on kinds 0/1 fall through safely.`

**So "reuse the MIDI schedule for Tier B events" runs into two walls the report does not price:**

1. **Payload width.** The only free fields are `pitch`/`velocity`, both `UInt8`. A modulation value
   riding those gets **8-bit resolution** — acceptable for a trance gate's on/off, visibly coarse
   for a stepped filter sweep. Widening the POD is explicitly guarded against by that comment.
2. **Scope.** `MIDIEventSchedule` is documented as the schedule for **"ONE instrument track."**
   Modulation must also reach **effect** parameters, which this schedule does not address at all.

⭐ The kind-byte *is* genuinely extensible — kinds 2/3/4 (CC/bend/pressure) were added additively and
the header records that consumers switching on 0/1 fall through safely. So a kind 5 is cheap. **The
event bus is reusable; the payload budget and the per-instrument scoping are not.** The architect
must decide between a parallel modulation-event schedule and a widened one, with eyes open.

### ⛔ CORRECTION 2 — the SVF's coefficients are SHARED ACROSS VOICES, so "auto-wah is free" splits in two

`Sources/DAWEngine/Instruments/PolySynthInstrument.swift` — `:18` and `:291` describe a "2-pole SVF
(Simper TPT form, **shared coefficients**)", with per-voice integrator state only (`ic1eq`/`ic2eq`,
`:73-74`) and coefficients `svfA1`/`svfA2` computed once (`:295`).

That shared-coefficient design is exactly *why* PolySynth is cheap, and it means the report's
"tremolo / auto-wah / vibrato are free once Tier A ships" is true for one case and false for the other:

- **Modulating a filter EFFECT** (post-mix, one instance, one coefficient set) — genuinely cheap.
  This is the auto-wah case, and it is free as claimed.
- **Modulating a SYNTH's per-voice filter** (a filter envelope, the thing players actually want) —
  **not** cheap: per-voice modulation depth requires per-voice coefficients, multiplying the
  `tan()`-based derivation by the voice count on every update.

**These are different features that sound similar when described in English**, and conflating them
is how a filter envelope gets scoped as an afternoon and costs a week. The architect must name which
one m39-e delivers. A defensible first answer is: effect-level filter modulation in Tier A, and
per-voice filter envelopes deferred with their real cost stated.

## 9. ⚠️ THE ONE TENSION THE ARCHITECT MUST RESOLVE — two reports converge on a reuse I have measured as constrained

> ⛔ **SUPERSEDED BY §10 — READ THAT FIRST.** The ⓐ/ⓑ/ⓒ options below are framed around the wrong
> schedule. `AutomationSchedule` already carries Float values at arbitrary sample time and already
> addresses effect params via `AutomationTarget`, and per-sample ramping ALREADY SHIPS for gain and
> pan. §10 adds option **ⓓ**, which may make this entire tension moot.

**Both** `2026-09-19-modulation-macros.md` (§7, Tier B) **and** `2026-09-19-dj-loop-fx.md` reached the
same conclusion independently, without seeing each other's work: rhythmic/edge-accurate effects
cannot ride the ~93.75 Hz control rate, and the fix is to reuse the **sample-accurate
`MIDIEventSchedule`** machinery.

Their agreement is real evidence — they computed the edge bias separately and agree with each other
and with my own figure (0–10.667 ms late bias, mean ~5.3 ms ≈ 4.5 % of a 128 BPM sixteenth, worst
case ~9.1 %, and **inconsistent edge to edge**, which is what makes it audible as sloppiness rather
than as latency).

⛔ **But §8 above records what I measured in the struct itself: `ScheduledMIDIEvent` is a full
24-byte POD whose only free fields are two `UInt8`s, and `MIDIEventSchedule` is scoped to ONE
instrument track — so it cannot address effect parameters at all.**

**This is not a contradiction and must not be flattened into one.** The DJ report is careful in its
wording — it says reuse the *pattern*, "(or a self-contained transport-aware sequencer)". The
modulation report is the one that leans harder on reusing the machinery. So the resolution space is:

- ⓐ **Copy the pattern, not the struct** — a parallel `ModulationEventSchedule` with its own POD
  sized for a real value (Float, not `UInt8`) and its own per-track/per-effect scoping. Costs a
  second schedule; buys full resolution and correct addressing. **Currently my default.**
- ⓑ **Add kind 5 to the existing schedule** — cheap, additively safe (kinds 2/3/4 were added this
  way and the header documents that consumers switching on 0/1 fall through safely), but inherits
  8-bit values and instrument-only scoping. Defensible ONLY for on/off gating.
- ⓒ **Widen the POD** — explicitly guarded against by the struct's own comment; would need that
  comment's reasoning overturned on measurement, not on convenience.

⭐ **The decision is load-bearing in the literal sense: it determines whether a trance gate and a
stepped filter sweep are the same feature or two.** ⓑ can gate but cannot sweep.

⚠️ **Do not let the two reports' agreement substitute for checking the struct.** They agree because
they reasoned from the same correct premise (the control rate is too coarse), not because either
one verified the payload budget — neither read `MIDISchedule.swift:14-26`. Converging conclusions
from a shared premise are one piece of evidence, not two.

## 10. ⛔⛔ RETRACTIONS AND A MAJOR FINDING — §8 AND §9 ARE SUPERSEDED HERE. READ THIS BEFORE THEM.

Two claims I wrote in §8/§9 were wrong, and correcting them opens a much cheaper design than any of
the options I listed. A false constraint in the input gets faithfully designed around, so this
section governs.

### ❌ RETRACTED — "modulation events would get 8-bit resolution"

**Wrong.** `Sources/DAWEngine/MIDISchedule.swift:23` already shows the trick in use:

```swift
static let pitchBend: UInt8 = 3   // pitch = LSB (low 7), velocity = MSB (high 7)
```

Kind 3 **already spans both `UInt8` fields for 14-bit resolution**. A kind-5 modulation event can do
the same: **16,384 steps**, which is not "visibly coarse for a stepped filter sweep" — it is finer
than MIDI CC and finer than most hardware sequencers. My resolution objection to option ⓑ collapses.

### ⚠️ PARTIALLY RETRACTED — "`noteID: UInt64` is 8 free bytes for a target address"

**Not free.** `:151` — *"controller events consume IDs from the same running counter"*, so kinds
2/3/4 already populate it; and `:99` puts `noteID` in the **sort key** as the final tiebreaker
(`(sampleTime, kindRank[off BEFORE on], pitch, noteID)`). Repurposing it for an address is not
impossible, but it is not free real estate either — it would need the sort-determinism invariant
re-examined, not just the field re-typed.

### ✅ THE SCOPING WALL STANDS, AND IS NOW THE *ONLY* REAL OBJECTION TO ⓑ

`MIDIEventSchedule` remains documented as the schedule for **"ONE instrument track"**. It cannot
address effect parameters. That, not payload width, is the discriminator.

### ⭐⭐⭐ THE FINDING THAT CHANGES THE DESIGN — per-sample ramping ALREADY SHIPS HERE

I had been weighing modulation schedules while the answer sat in the automation path. Measured in
`Sources/DAWEngine/Automation/AutomationRenderer.swift`:

- **Gain ramps PER SAMPLE across the block** (`:241-258`) — `applyGainRamp` computes
  `let step = (gainEnd - gainStart) / Double(frameCount)` and then
  `data[frame] *= Float(gainStart + step * Double(frame))`. It even short-circuits a whole-quantum
  unity block to stay bit-exact.
- **Pan ramps PER SAMPLE too** (`:261-265`) — *"a moving pan ramps the pan VALUE per sample and
  applies per-sample equal-power gains (trig on the render thread is lock/alloc-free)"*.
- ⛔ **Effect parameters do NOT.** `storeEffectParams` (`:162-189`) calls
  `AutomationSchedule.value(at: renderStart, …)` **once per quantum** and pushes a single scalar via
  `storeAutomatedParam(slot:value:)`. `renderStart` is the value at the START of the block, held
  for its whole duration.

**Three consequences the architect must build on:**

1. **The zipper-noise mitigation the synthesis report told us to price is already implemented,
   in production, RT-safe — just not on the effect-param path.** Nobody needs to invent it. The
   question is whether to extend the proven gain/pan pattern to effect params, and the honest cost
   is not the DSP: it is that `storeAutomatedParam(slot:value:)` takes a **scalar**, so carrying a
   ramp means a `(start, end)` interface change reaching all 11 effects. That is the real number to
   put in the design, and it is an interface-migration cost, not a DSP one.
2. **"93.75 Hz is our control rate" is TRUE FOR EFFECT PARAMS AND FALSE FOR GAIN/PAN.** Volume and
   pan modulation are already continuous. So **tremolo and auto-pan are cheaper than any report
   claimed** — they ride a path that already interpolates.
3. **`AutomationSchedule.value(at:)` takes an ARBITRARY `Int64` sample time and carries a cursor for
   sequential access, and `AutomationTarget` already addresses effect params.** That makes a fourth
   option real, and it is the one I now favour:

### ⓓ SPLIT THE RENDER BLOCK AT BREAKPOINT SAMPLE TIMES — evaluate, do not assume

Rather than a second event schedule, sub-divide the render quantum at the exact sample offsets where
edges fall, which is standard DAW practice and what `value(at:)`'s arbitrary-time signature already
supports. If it works, **Tier B needs no new schedule at all**, and the ⓐ/ⓑ/ⓒ tradeoff in §9 is
moot.

⚠️ **This is a CHECK FOR THE ARCHITECT, NOT A CONCLUSION.** I have read `AutomationRenderer`'s
gain/pan/effect-param paths and `value(at:)`'s signature; I have **not** established what splitting a
quantum costs where effects hold internal state across a block, nor whether every effect tolerates
being called with short sub-blocks. Some filters and all delay-based effects may not. **Verify
before adopting.**

## 11. ⛔ §8 CORRECTION 2 IS ITSELF CORRECTED — I reasoned, the architect measured

`docs/design/2026-09-19-modulation-layer.md` contradicts my §8 Correction 2 **on magnitude**, with a
benchmark rather than an argument, and it is right.

I wrote that per-voice filter modulation "multiplies the `tan()` derivation by voice count" and
framed it as an order-of-magnitude blocker. The architect measured the SVF coefficient triple at
**11.5–18.2 ns** (`swiftc -O`, two runs): per-voice at a 32-frame stride is **~0.04 % of a core for a
16-voice track**.

⭐ **Both statements are true and only one is relevant.** The 16× ratio I identified is real — I was
not wrong about the mechanism. I was wrong to treat a ratio as a cost without ever measuring the
base. **A multiplier on a negligible quantity is still negligible**, and "16× more expensive" reads
as decisive right up until someone measures that the thing being multiplied costs 12 ns.

⚠️ **The real blocker for per-voice filter envelopes is elsewhere** — envelope state and trigger
plumbing, not arithmetic. Filed by the architect as `m39-e-D2`.

**The lesson worth keeping is about my own method, not the SVF.** §7–§10 of this document were
written to be trusted as verified fact, and the architect was told to treat them that way. This
entry is here because one of them was reasoning wearing verification's clothes: I read the code
correctly, derived a ratio correctly, and then asserted a *consequence* I had not measured. **A
verified mechanism is not a verified cost.** Where these sections state a magnitude rather than a
fact about the source, treat it as a hypothesis until someone benchmarks it.
