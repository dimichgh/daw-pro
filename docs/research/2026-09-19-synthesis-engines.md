# Research — Synthesis engines: what makes a preset rich, and what should DAW Pro build

**Date:** 2026-09-19
**Scope:** Should DAW Pro build its own synthesis instruments (beyond PolySynth), and which. Desk
research (product docs, DSP references, academic papers) + direct codebase grounding. No code
touched.

## 0. Grounding: what we actually have today (verified by reading the code, not the pitch)

Read directly: `Sources/DAWEngine/Instruments/PolySynthInstrument.swift`,
`Sources/DAWCore/Model.swift` (`PolySynthParams`, `InstrumentDescriptor`), `docs/ARCHITECTURE.md`
(Instrument sections), `docs/research/design-au-parameter-surface.md`,
`docs/research/design-m10n-instrument-library.md`, `docs/research/2026-07-16-free-instruments.md`.

- **PolySynth** — 16-voice, one `InstrumentDescriptor.Kind` case (`.polySynth`). Per voice: a single
  polyBLEP/naive oscillator (saw/square/triangle/sine, `PolySynthParams.Waveform`) → one 2-pole
  Simper-TPT SVF low-pass (cutoff 40 Hz–18 kHz, resonance 0–1 mapped to Q 0.5–10) → one linear ADSR
  (attack 0.5 ms–5 s, decay 1 ms–5 s, sustain 0–1, release 1 ms–8 s) × velocity × 0.25 headroom, then
  a single output-gain scalar. Honors pitch-bend (±2 st, GM-fixed) and sustain (CC64) at the
  controller level; `pedalHoldLimit` (m34-q) caps how many pedal-held notes may ring. **That is the
  entire signal path** — no LFO, no second envelope, no unison, no sub-oscillator, no noise, no FM,
  no wavetable, no saturation.
- **Render-thread contract (load-bearing for everything below):** `apply(params:)` publishes an
  immutable POD snapshot; the render thread adopts it at the top of the next quantum and
  **recomputes filter/envelope coefficients only on generation change — never per sample**
  (`PolySynthInstrument.swift:24-30, 176-184`). This is why PolySynth is cheap: a `tan()` call for
  the SVF coefficients happens once per parameter edit, not once per sample. Any modulation source
  that must move a coefficient *while a note is sounding* (an LFO, a filter envelope, audio-rate FM)
  breaks this contract and is a materially different, more expensive render path — not a bigger
  `struct`.
- **Sampler** — rich: zones, keymaps, varispeed, round-robin, mono choke, glide/legato (per
  `Sources/DAWEngine/Instruments` and the M32 sample-flip milestone). Sample **playback**, not
  synthesis.
- **SoundBank** — SF2/DLS via the system `AUSampler`, reference-in-place library
  (`design-m10n-instrument-library.md`). Also playback, not synthesis.
- **HostedAU** — third-party AudioUnit hosting via `AUHostRegistry`; `au.describeParams`/`au.setParam`
  (`design-au-parameter-surface.md`, confirmed implemented — 19 call sites in `Commands.swift`) give
  an agent a generic, paged, JSON view of *any* hosted AU's `AUParameterTree`.

There is no `.fmSynth`, `.wavetableSynth`, or `.drumSynth` kind today. `InstrumentDescriptor.Kind`
(`Model.swift:1599-1612`, verified 2026-09-19) currently has five cases — `testTone`, `polySynth`,
`sampler`, `audioUnit`, `soundBank` — and has grown additively three times before (`sampler`,
`audioUnit`, `soundBank` each arrived as a new case with an additive-optional payload field,
`Model.swift:1617-1627`) — that is the precedent a new synthesis engine would follow. (Two prior
research docs, `design-m10n-instrument-library.md` and `2026-07-16-free-instruments.md`, cite older
line numbers for this same struct — `:659-681` and `:1226-1241` respectively — because `Model.swift`
has grown substantially since both were written; the numbers above were re-verified against the
current tree for this report, not copied forward.)

## 1. Why build now — the AU-hosting alternative was already tried and has two dated, unresolved problems

The 2026-07-16 free-instrument survey (`docs/research/2026-07-16-free-instruments.md`) concluded
the opposite of this report's recommendation: "no code/architecture changes indicated... the
existing AU-hosting + SF2/DLS pipeline already covers everything." That was correct *for filling
sample-library gaps*. It is the wrong lens for synthesis specifically, for two reasons discovered
**after** that doc shipped:

1. **Hosting is not free of engine risk.** On 2026-07-20, calling `track_set_instrument` with a
   hosted third-party AUv2 instrument (Surge XT) wedged the app's main actor for roughly 3.5 minutes
   — every control-plane command failed with "main actor unresponsive" until the AU finished
   instantiating on its own. A follow-up standalone probe
   (`docs/research/m23av-routeb-feasibility-probe.md`, 2026-08-04) showed the bare in-process
   instantiate path is fast when warm (~0.18 s total) and that macOS can bridge classic AUv2
   instruments out-of-process — but **the remote plugin-view path is exactly where the original wedge
   was reported and remains unvalidated**, because a headless probe cannot construct the
   `NSApplication`/ViewBridge context that path needs. An agent cannot safely assume a hosted
   third-party synth is wedge-free; an in-process, first-party render path removes the question
   entirely.
2. **A hosted AU's parameter surface is generic, not semantic.** `au.describeParams` returns
   `identifier`/`displayName` strings *as the vendor wrote them* — for a built-in Apple AU that's
   `"delayTime"`; for a typical commercial synth it can be `"OSC 1 Wave"`, `"Env2>Cutoff"`, or a
   raw index with no name at all if the AU declines to publish a tree (`hasParameterTree:false` is
   documented as a *normal, successful* answer). An LLM driving a hosted synth is reverse-engineering
   an opaque per-instance address space through trial-and-error `au.setParam` calls and a re-render
   to check what moved. An LLM driving our own instrument gets a **typed, documented, stable Swift
   struct** (`PolySynthParams` is the existence proof) with fixed field names, fixed ranges, and a
   wire/MCP surface designed for exactly this purpose.

Net: hosting remains the right answer for *sample content* (orchestral libraries, drum kits,
anything requiring gigabytes of recorded material — see the free-instruments survey). It is the
wrong answer for *synthesis*, where the entire value is a small, fast, semantically legible
parameter space an agent can reason about and a render thread we control end to end. This is the
actual case for the sprint: own the render path, own the parameter names.

## 2. Engine families

### 2.1 Subtractive (what we have)
Start from a harmonically rich waveform, carve it with a filter. Cheap, well understood, the entire
PolySynth today. The gap isn't the technique — it's that we stopped at *one* oscillator through *one*
filter with *one* envelope, which is the textbook definition of thin.

### 2.2 FM / phase modulation (DX7 lineage)
The DX7 (1983) is **phase modulation**, not frequency modulation, despite the name: modulating a
carrier's *phase* with another oscillator is mathematically equivalent to modulating its frequency
with that oscillator's derivative — a subtlety that matters for stability but not for the sound
[Righto: DX7 chip reverse-engineering](https://www.righto.com/2021/12/yamaha-dx7-chip-reverse-engineering.html).
6 operators, 32 fixed **algorithms** (routing graphs of which operators modulate which), and
**feedback** — an operator's output fed back into its own phase — which is specifically how the DX7
produces sawtooth-like, harmonically dense tones from pairs of sine operators
[Righto, same]. Stacking three operators in series (A→B→C) is "FM of FM": the spectrum becomes a
convolution of two FM operations, far richer than a single carrier/modulator pair. Modern
implementations (Ableton Operator, Dexed, Surge's FM2/FM3 oscillator types) usually cut this down to
2–4 operators with a handful of fixed algorithms rather than the DX7's full 32 — the fidelity loss
is small and the parameter surface an order of magnitude easier to reason about.
[Ableton Operator](https://www.ableton.com/en/packs/operator/) ·
[ajxs.me DX7 technical analysis](https://ajxs.me/blog/Yamaha_DX7_Technical_Analysis.html)

### 2.3 Wavetable (position scanning, morphing, spectral warping)
A wavetable is a set of single-cycle waveform "frames"; the oscillator reads a **position** through
the set (0–1, often modulated) instead of one fixed shape, interpolating between adjacent frames.
"Spectral warping" is the modern addition on top: instead of just crossfading frames, warp the
*harmonics themselves* — stretch, shift, smear, skew — a technique Vital popularized and Serum 2 has
now extended to per-oscillator "spread/gate/mask" operations on a live-resynthesized spectrum
[Vital](https://vital.audio/) ·
[unison.audio, Serum 2](https://unison.audio/xfer-serum-2/) (2025-03).
Massive X takes a different angle on the same table format: **10 different read modes** per
oscillator (hard-sync, formant, a wavetable-bending "Gorilla" mode, etc.), each with its own
sub-parameters, so the same 170-table library produces far more timbral range than position-scan
alone [NI Massive X details](https://www.native-instruments.com/en/products/komplete/synths/massive-x/details/).

### 2.4 Additive
Sum many independent sine partials, each with its own amplitude/pitch (and often its own envelope).
Logic's Alchemy exposes up to **600 independently controllable partials** in its additive engine, and
pairs it with a "spectral" mode that resynthesizes *imported audio* as manipulable partial data
[MusicRadar, Alchemy guide](https://www.musicradar.com/news/ultimate-guide-alchemy-logic-pro). Additive
is the most literal way to sculpt a target spectrum, and — see §7 — the mode where exhaustive,
tedious-for-a-human parameter setting is exactly what an agent is good at.

### 2.5 Granular
Chop a source (sample or synthesized signal) into short **grains** (typically 10–100 ms; below ~13
ms at high pitch / ~45 ms at low pitch, individual grains stop reading as a pitched tone) and
re-trigger them at a controllable **density**, **position** (with **spray**/scatter for randomizing
source offset), and independent **pitch**
[Native Instruments granular guide](https://blog.native-instruments.com/granular-synthesis/) ·
[Sound on Sound, granular practical intro](https://www.soundonsound.com/techniques/granular-synthesis-practical-introduction).
Cheap per-grain DSP, but the engineering cost is in the **scheduler** (many overlapping,
independently-aged voices per note) and the **asset pipeline** (it needs source material — our
existing Sampler content is a ready-made feed for this).

### 2.6 Physical modelling — Karplus-Strong and digital waveguides
Karplus-Strong (1983) models a plucked string with almost no DSP: fill a delay line (length = one
period of the target pitch) with noise or an impulse, then repeatedly average each pair of adjacent
samples back into the line. That averaging *is* a one-zero low-pass filter, and it naturally damps
high frequencies faster than low ones — exactly how a real string loses its pluck brightness first
[Stanford, Sound and Music: Karplus-Strong](http://crypto.stanford.edu/~blynn/sound/karplusstrong.html).
Julius O. Smith showed this is a special case of the more general **digital waveguide** model — a
bidirectional delay line literally simulating wave travel along a string or tube, which generalizes
to horns, bars, and plates with different termination/loss filters
[Wikipedia, digital waveguide synthesis](https://en.wikipedia.org/wiki/Digital_waveguide_synthesis) ·
[Wikipedia, physical modelling synthesis](https://en.wikipedia.org/wiki/Physical_modelling_synthesis).
Surge XT ships a "String" waveguide oscillator type built on exactly this
[sunsetsilencio, Surge XT](https://www.sunsetsilencio.com/blog/exploring-surge-xt/). This is
genuinely one of the **cheapest** ways to add a synthesis family that sounds nothing like subtractive
or wavetable: a short delay line and a one-pole filter per voice.

### 2.7 Modal synthesis (the drum/mallet-relevant physical-modelling variant)
Instead of a delay line, represent a resonant object (bell, drum shell, marimba bar) as a small bank
of exponentially-decaying sinusoids ("modes"), each at a fixed frequency ratio to a fundamental with
its own decay time. This is the physically-informed generalization of "808 = sine + pitch envelope":
a handful of tuned, independently-decaying resonances instead of one. Pigments (Arturia) ships a
dedicated modal engine for exactly this character
[Arturia, Pigments sound design](https://www.arturia.com/products/software-instruments/pigments/sound-design).

### 2.8 Sample + synthesis hybrids
Layer a sampled transient/body with a synthesized tail, or resynthesize a sample's spectrum and
continue manipulating it as synthesis data. Alchemy's "spectral" mode (import audio → partial data →
stretch/smear/re-pitch while preserving character) and Serum 2's new "Spectral" oscillator (drag in
a sample, get real-time harmonic resynthesis, spectral spread/gate/mask, even vocoding from another
oscillator) are the two current flagship examples
[MusicRadar Alchemy](https://www.musicradar.com/news/ultimate-guide-alchemy-logic-pro) ·
[unison.audio Serum 2](https://unison.audio/xfer-serum-2/). This is a natural extension point for
*us* specifically because we already own a rich Sampler with real audio content — a hybrid engine is
mostly "point an oscillator at Sampler zone data" rather than a new asset pipeline.

### 2.9 Phase distortion (Casio CZ) vs. vector synthesis (Sequential Prophet-VS / Korg Wavestation)
Two 1980s techniques that are often confused. **Phase distortion** warps the *phase* of a single
read pointer through one fixed waveform (a sine, read at a variable, non-linear rate) — the CZ's
"DCW" parameter morphs a sine continuously into a square/saw shape, explicitly analogous to a
filter's cutoff but achieved with zero filtering
[Wikipedia, phase distortion synthesis](https://en.wikipedia.org/wiki/Phase_distortion_synthesis).
**Vector synthesis** instead crossfades between *several separately-recorded/synthesized waveforms*
positioned at the corners of a 2D (or, on the Wavestation, sequenced) pad, and a joystick/envelope
moves the mix point between them over time — the Wavestation extended this to crossfading up to 255
waveforms in a programmable sequence ("wave sequencing")
[Wikipedia, Korg Wavestation](https://en.wikipedia.org/wiki/Korg_Wavestation). Vector synthesis's
"morph between N corner presets" shape reappears almost unchanged in Alchemy's transform pad and
Pigments' XY engine blend — see §5, it is the one classic technique whose UI metaphor (agent
authors the corners, a human — or another agent call — drags the point) maps almost perfectly onto
an AI-native DAW.

### 2.10 Virtual analog with drift
"Virtual analog" (Diva, Sylenth1, Surge's classic oscillator) means a digitally-modeled analog
circuit, and the detail that separates a convincing one from a thin one is **imperfection**: real
analog oscillators drift in pitch over time, their waveforms are slightly asymmetric, filters
saturate before they clip cleanly, and envelope timing has small circuit-driven variance. u-he Diva
explicitly models this per-oscillator (drift, waveform asymmetry) with a "Trimmers" panel exposing
drift amount as its own control, and combines it with **zero-delay-feedback (ZDF)** filter modeling
— circuit simulation run in real time rather than a fixed-form filter equation — for authentic
resonance behavior
[u-he Diva product page](https://u-he.com/products/diva/) ·
[Syntorial, Diva highlight](https://www.syntorial.com/highlights/uhe-diva/). This is a *modifier* on
top of subtractive synthesis, not a new engine family — and one of the cheapest richness upgrades
available to PolySynth specifically (see §3).

## 3. What separates a thin preset from a rich one

These are largely *modifiers* layered on any of the engines above, not engines themselves — which is
why they matter independently of which new instrument(s) we build.

- **Unison / detune / voice spread.** Stack N (commonly up to 16) slightly-detuned copies of the
  same voice, spread across the stereo field, each with randomized starting phase. This is the
  single highest-payoff, lowest-conceptual-complexity richness feature that exists — Sylenth1's
  entire reputation rests on "eight unison voices, alias-free, with a huge usable sweet spot"
  [musicproductionwiki, Sylenth1 review](https://musicproductionwiki.com/articles/sylenth1-review),
  and Vital ships 16-voice unison with phase randomization as a baseline expectation
  [Vital](https://vital.audio/).
- **Oscillator drift / analog modelling.** Slow, small per-voice random walk on pitch (and
  optionally waveform shape). See §2.10 — Diva.
- **Sub-oscillator.** A second, simpler oscillator one or two octaves below the main pitch, usually
  a fixed sine or square, for low-end weight without retuning the main oscillator's timbre.
- **Noise layer.** A dedicated noise source mixed under/over the tonal oscillators — essential for
  breathy pads, percussive attacks, and (see §4) most drum synthesis.
- **Velocity / key tracking.** Filter cutoff and/or amplitude scaling with note velocity and/or pitch
  — the difference between a patch that sounds identical in every register/dynamic and one that
  behaves like a real instrument (brighter and louder when struck harder, darker in the bass).
- **Per-voice randomization.** Small random offsets (pan, detune, filter cutoff) applied per note-on,
  independent of the deliberate unison stack — the "no two notes sound quite the same" effect real
  instruments have for free.
- **Filter self-oscillation.** At very high resonance a state-variable filter (like our own SVF)
  becomes an oscillator in its own right — a free extra sound source if the resonance range is
  allowed to go high enough (our current `resonanceRange` maps 0–1 to Q 0.5–10; self-oscillation
  needs headroom above that).
- **Saturation in the filter/signal path.** A `tanh`-style waveshaper before or after the filter adds
  harmonics and perceived loudness/warmth "for free" — one of the cheapest DSP additions with
  outsized perceptual payoff.
- **Envelope curve shape.** Real ADSRs are not straight lines — exponential/logarithmic segments
  read as more natural than the linear ramps PolySynth uses today (`PolySynthInstrument.swift:241-266`
  is explicitly linear). A curve exponent parameter (or a small set of named curve shapes) is a
  cheap per-sample change to an already-per-sample computation — it does **not** touch the
  once-per-generation coefficient contract.
- **Macro controls.** One user- (or agent-) defined knob mapped to several destinations at once with
  independent depths and polarities — Massive X's flexible routing and Meld's two macros-per-engine
  are the modern examples
  [NI Massive X](https://www.native-instruments.com/en/products/komplete/synths/massive-x/details/) ·
  [Ableton Meld](https://www.ableton.com/en/blog/meld-a-look-at-live-12s-new-bi-timbral-synth/). This
  is architecturally a **MODULATOR** primitive (source → multiple `dest × depth` pairs), not a scalar
  PARAM — see §6's PARAM/MODULATOR/PRESET framing.

## 4. Drum / percussion synthesis specifically

Classic drum-machine synthesis is a **different discipline** from the melodic engines above: no
sustain, no pedal, no voice stealing in the polyphonic sense — one-shot voices whose *envelopes are
the timbre itself*.

- **808-style kick.** The real TR-808 circuit is close to a self-oscillating filter: a trigger pulse
  excites a filter almost at the edge of oscillation, producing a tone whose pitch rises briefly then
  decays exponentially while the oscillation itself fades — giving pitch decay and amplitude decay
  "for free" from one circuit
  [Perfect Circuit, kick drum synthesis](https://www.perfectcircuit.com/signal/kick-drum-synthesis).
  The **standard software model** decomposes this into a sine oscillator plus **two independent
  exponential envelopes**: a fast one that sweeps pitch down from a start frequency to the base note
  (this tiny drop is what reads as "impact" rather than "tone"), and a slower one on amplitude that
  lets the low-frequency tail ring out
  [Unison.audio, 808 drum](https://unison.audio/808-drum/). Every one of these is a scalar PARAM.
- **909-style snare.** A tonal component (one or two pitched oscillators — the "drumhead" modes) plus
  a noise component run through a **lowpass→highpass (bandpass) filter chain**, each with its own
  envelope, mixed together
  [McGill, percussion synthesis chapter](https://cim.mcgill.ca/~clark/nordmodularbook/nm_percussion.html).
- **909-style / metallic hats.** Multiple (traditionally six) square-wave oscillators at inharmonic
  frequency ratios, mixed and often **ring-modulated** against each other for metallic clang, then
  passed through a bandpass filter with its own decay envelope and a final VCA envelope
  [McGill percussion chapter](https://cim.mcgill.ca/~clark/nordmodularbook/nm_percussion.html) ·
  [ModWiggler, 808→909 hats](https://modwiggler.com/forum/viewtopic.php?t=259594).
- **Transient/click design.** A very short (sub-5 ms) noise or impulse burst layered at the very
  start of a kick/snare voice, independent of the main body's envelope, is what reads as "punch" —
  cheap, and describable in plain language ("more click", "softer attack").

Modal synthesis (§2.7) is the natural upgrade path beyond literal 808/909 recreation for toms, congas,
and metallic percussion that a pure subtractive kick/snare model can't reach — a small bank of tuned,
independently-decaying modes instead of one or two oscillators.

## 5. Product standout-feature survey — one feature each, and is it worth copying

| Product | Standout feature | Genuinely novel to copy? |
|---|---|---|
| [Serum 2](https://unison.audio/xfer-serum-2/) (Xfer, updated 2025-03) | 5 oscillator engines incl. a live-resynthesizing **Spectral** oscillator (spread/gate/mask/vocode any dragged-in sample) + post-mix modulation (route an LFO to a mixer channel's *level*, not just a param) | Post-mix-to-level modulation is cheap and worth copying once we have any modulation routing at all. Full spectral resynthesis is heavy DSP — defer. |
| [Vital](https://vital.audio/) (free "Basic" tier is the full engine, as of 2026-06 pricing survey) | **Spectral warping** (stretch/shift/smear/skew harmonics, not just crossfade frames) + 16-voice unison with phase randomization; **GPLv3**, source is readable for reference. Its paid "Plus" tier also ships **text-to-wavetable**: type words, the tool renders them as speech and resynthesizes that recording into a formant-preserving wavetable — a text-to-*speech-timbre* pipeline, not literal semantic text-to-timbre (typing "warm bass" does not produce a warm bass; typing a spoken phrase produces a robotic-vocal wavetable of that phrase). | Wave-warp modes (sync/formant/quantize as cheap nonlinear transforms of the table read pointer) are buildable at low cost and are most of Vital's perceived "richness." Source is a legitimate DSP reference (with license awareness — GPLv3 code cannot be copied verbatim into our proprietary codebase, only studied). |
| [Surge XT](https://surge-synthesizer.github.io/) (open source, GPL3 — [FAQ](https://surge-synthesizer.github.io/faq/)) | Dual-scene layering, 12 LFOs with full DAHDSR, a multi-segment envelope (up to 128 nodes), **and a Lua-scripted "Formula" modulator** [sunsetsilencio survey](https://www.sunsetsilencio.com/blog/exploring-surge-xt/) | The Formula/Lua modulator is the one item on this whole list that is *already* an agent-authorable primitive: instead of hand-tuning an LFO shape, an agent emits a small script. Directly relevant to our MCP-driven positioning — see §6. |
| [Kilohearts Phase Plant](https://kilohearts.com/products/phase_plant) | Modular "snapin" chain — generators and 28 shared effect modules dropped into up to 3 ordered lanes, entirely in one screen | The *ordered-list-of-named-modules* shape maps cleanly onto a JSON array an LLM can emit directly. Worth studying for our effects-chain UX generally, lower priority for the synth engines themselves. |
| [Massive X](https://www.native-instruments.com/en/products/komplete/synths/massive-x/details/) | 10 distinct wavetable **read modes** per oscillator (formant, hard-sync, "Gorilla" table-bending, etc.) plus freely reconfigurable audio routing between oscillators/modulators | The read-mode concept (several cheap nonlinear reinterpretations of the same table data) is a good multiplier on wavetable investment — defer to a wavetable v2, not v1. |
| [Arturia Pigments](https://www.arturia.com/products/software-instruments/pigments/sound-design) | Up to two of five different engines (VA / wavetable / granular / additive / **modal**) run in parallel, plus a fully generative step-modulation sequencer | The generative sequencer is a strong **MODULATOR**-class target an agent can author directly (emit a step pattern) rather than tune by ear. Modal engine directly informs §2.7/§4. |
| [Spectrasonics Omnisphere](https://www.spectrasonics.net/products/omnisphere/omnisphere-features.php) | Granular engine that accepts **any user audio file as a soundsource**, plus the "Orb" circular real-time-manipulation performance controller | "Any audio as a granular source" is the one feature that costs us almost nothing extra — we already have a Sampler with real audio content to feed it. |
| [u-he Diva](https://u-he.com/products/diva/) | Per-oscillator circuit-accurate drift/asymmetry modeling + zero-delay-feedback filters | Drift is a cheap, high-payoff bolt-on to our *existing* PolySynth oscillator/filter — see §3, §8. |
| [Sylenth1](https://musicproductionwiki.com/articles/sylenth1-review) | Not a technique — a *quality bar*: 4 alias-free oscillators, huge-sweet-spot 8-voice stereo unison, very low CPU, nothing exotic | The lesson, not a feature: unison implementation **quality** (alias-free, wide usable range) matters more than unison **feature count**. Sets the bar for whatever unison we ship. |
| [Ableton Operator](https://www.ableton.com/en/packs/operator/) | Deliberately small: 4-operator hybrid FM/additive/subtractive with one filter, no wavetables, limited unison, aging UI — and is still considered "underrated" for sound design | Direct blueprint for a minimal-viable FM engine: few operators, a handful of fixed algorithms, one filter stage, nothing more. |
| [Ableton Wavetable](https://www.ableton.com/en/packs/wavetable/) | 2 oscillators + a **deliberately small** mod matrix (3 envelopes, 2 morphable LFOs) rather than a sprawling one | Proof that a small, fixed modulation set reads as "rich enough" — supports scoping our own mod system down rather than building a full Vital-class matrix. |
| [Logic Alchemy](https://www.musicradar.com/news/ultimate-guide-alchemy-logic-pro) | Additive (600 partials) + spectral resynthesis of imported audio + a 4-corner **transform/morph pad** | The transform pad is the clearest human/AI split feature on this entire list — see §6. Not distributable outside Logic, but the *idea* is free to copy. |

## 6. What an AI agent can uniquely do with a synth

First, the framing this whole report is built on — every capability below (and every row in §7) is
one of exactly three things to an LLM driving our control protocol:

- **PARAM** — a scalar (or small fixed struct) the agent sets with one wire command
  (`track.setInstrument` with a params payload, matching `PolySynthParams` today). Cheap to reason
  about, cheap to build, cheap to test — this is what PolySynth already is end to end.
- **MODULATOR** — a `source → destination × depth` *routing* the agent authors (an LFO shape,
  Surge's Lua formula, a macro's fan-out, a generative sequencer's step list). This is expressive but
  is the one that breaks PolySynth's "recompute coefficients only on generation change" contract —
  see §0 and §8. It needs either per-sample/per-block recomputation (a new render-path cost) or a
  deliberately bounded "block-rate modulation" compromise (§8).
- **PRESET** — a whole named state the agent picks, blends between, or generates wholesale (a
  wavetable, a 4-corner morph set, a drum kit's 8 pad assignments). Cheap to *drive* (one command
  sets/loads it) but potentially expensive to *author* (may need an asset pipeline).

What follows from that framing:

1. **Closed-loop sound matching is buildable with infrastructure we already have, today.** We do not
   need a bespoke ML model to let an agent "describe a target timbre and have params solved for it."
   The loop is: render a candidate preset offline (proven working, sample-exact — the m25-n PDC
   measurement), measure it (`instrument.probeLiveness` already computes centroid + RMS; `clip.analyze`
   is designed), compare to a target descriptor or reference clip, adjust PARAM values, repeat. This
   is a genuine ARCHITECTURE takeaway, not a research wish — see §9.
2. **Exhaustive/inverse parameter search is an active, citable research area**, and some of it
   targets exactly the kind of engine we're evaluating. Syntheon does deep-learning parameter
   inference *specifically for Vital* — audio in, best-matching Vital preset out
   [github.com/gudgud96/syntheon](https://github.com/gudgud96/syntheon). InverSynth (2018,
   [arXiv:1812.06349](https://arxiv.org/abs/1812.06349)) and DiffMoog
   ([arXiv:2401.12570](https://arxiv.org/html/2401.12570v1)) do the same for modular synths using
   differentiable DSP, letting gradient descent — not a human turning knobs — find the parameter
   vector that best reproduces a target sound. CTAG ("Creative Text-to-Audio Generation via
   Synthesizer Programming," ICML 2024, [arXiv:2406.00294](https://arxiv.org/abs/2406.00294)) goes
   one step further: it renders **text prompts** by iteratively updating a 78-parameter modular
   synth's settings — deliberately choosing a small, interpretable parameter space over an
   uninterpretable neural latent space specifically so a human can inspect and tweak the result
   afterward. That is precisely the argument for a small, typed, first-party PARAM surface over a
   hosted AU's opaque one (§1).
3. **Operator ratios and modulation indices are something an agent reasons about natively and a
   human finds opaque.** "Ratio 2:1, index 3.0" reliably produces a bell-like inharmonic spectrum;
   most human sound designers learn this by trial and error over years, while an LLM can reason from
   the underlying Bessel-function sideband math directly. This is the strongest "AI edge" argument
   for FM specifically among all the engine families surveyed.
4. **Exhaustive additive control.** Setting the amplitude/pitch of 600 independent partials by hand
   (Alchemy's ceiling) is impractical for a human; it is a mechanical, describable task for an agent
   working from an analyzed target spectrum. Low priority to build (§7 ranks it out of the top 3) but
   worth naming as a capability nobody else's *workflow* exploits even where the DSP exists.
5. **The morph-pad / vector-synthesis pattern is the cleanest human/AI split on the whole survey.**
   An agent authors 4 (or N) named corner presets from a text brief ("dark," "bright," "aggressive,"
   "airy"); a human — or a later agent turn — just drags a point between them. Alchemy's transform
   pad and vector synthesis generally (§2.9) are the existing precedent; it costs us one crossfade
   engine and reuses whatever PARAM surface the underlying voices already have.
6. **A scripted/Lua-style MODULATOR is an agent-native primitive, not a power-user escape hatch.**
   Surge XT's Formula modulator lets a sound designer write a short script instead of shaping an LFO
   by ear. For us this inverts the usual difficulty order: a general modulation *language* an agent
   can emit correctly is arguably **easier** to build well than a polished graphical mod-matrix UI,
   because the "UI" is just wire protocol validation.

## 7. Gap table

Format: **feature | who has it | musical payoff | DSP complexity | how would an LLM drive this
(PARAM / MODULATOR / PRESET)**. "DSP complexity" is scored against our *actual* render-path contract
(§0), not in the abstract — a feature that forces per-sample recomputation is flagged even when the
underlying math is simple.

### 7.1 Engine-family gaps (new instrument kinds)

| Feature | Who has it | Payoff | DSP complexity | LLM drive |
|---|---|---|---|---|
| FM/PM, 2–4 operators, fixed algorithms + feedback | DX7, Dexed, Ableton Operator, Surge (FM2/3) | High | **Low** — operators are phase-modulated sine oscillators; algorithm = a small fixed routing table; feedback is one scalar/operator. Each operator still needs its **own envelope** (the DX7's character is largely the modulation index moving over the note, i.e. the modulator operator's own amplitude envelope) — that's the same per-sample amplitude-ramp shape PolySynth's existing ADSR already runs, not a new coefficient-recompute cost. A `sin()`-per-sample-per-operator core (what our current sine waveform path already pays) is fine at 2–4 operators; a lookup-table sine is what keeps it cheap if operator count grows later. | **PARAM** (ratio, index, feedback, algorithm id, and a per-operator envelope's 4 numbers) — this is the family where PARAM-only control plays to an LLM's strength (§6.3) |
| Drum synth (808 kick / 909 snare / metallic hats, one-shot per pad) | TR-808/909 lineage, every DAW's stock drum synth | High | **Low** — one-shot voices, no sustain/pedal/voice-stealing logic to interact with; pitch-envelope-on-a-sine and noise-through-bandpass are both already-proven per-sample patterns (our ADSR is already per-sample) | **PARAM**, entirely — see the §8 surface. "Higher click, longer boom" maps directly to scalar fields. |
| Wavetable oscillator, position scan | Serum, Vital, Massive X, Ableton Wavetable, Pigments | High | **Medium** — position is a coefficient-per-generation change (cheap), but needs a **new asset format** (wavetable frame sets) and an authoring/import pipeline; interpolation between frames is per-sample but arithmetic-only (no filter-style stability math) | **PARAM** (position) + **PRESET** (which table) + a genuinely novel angle: the agent can *compose* a wavetable procedurally (render N frames offline from an additive/FM spec) rather than only picking one |
| Wavetable read modes (formant/hard-sync/table-bend) | Massive X | Medium | Medium — each mode is its own nonlinear read function; cheap once the base wavetable oscillator exists | **PARAM** (mode enum + 1-2 sub-params) |
| Granular engine | Serum 2, Omnisphere, Pigments | Medium-High (pads, vocal chops, textures nothing else here reaches) | **High** — needs a grain scheduler (many independently-aged overlapping voices per note) and an asset pipeline (source audio) | **PARAM** (grain size/density/position/spray/pitch) to drive; **PRESET**/asset choice (which Sampler zone feeds it) is the interesting agent-authored piece |
| Additive (N independent partials) | Alchemy (600), classic additive synths | Medium (mostly organ/bell/resynthesis territory) | Medium-High — N-oscillator bank with per-partial envelopes; cheap per-oscillator, expensive at N=100s | Half **PARAM-array**, half **PRESET** — a partial table is really a preset payload; the AI-unique angle is solving it from an analyzed target spectrum (§6.4) |
| Physical modelling — Karplus-Strong / waveguide (plucked string) | Surge XT ("String"), most modular/Eurorack contexts | Medium-High (a genuinely different sound class, not another filter-and-osc combo) | **Low** — a short delay line + one-pole averaging filter per voice; one of the cheapest ways to add an entirely new *family*, not just a modifier | **PARAM** (string damping, pluck brightness/position, decay) |
| Modal synthesis (tuned resonance bank) | Pigments | Medium-High for toms/mallets/metallic percussion specifically | Medium — small bank (~8–16) of resonant filters/decaying sinusoids, each independently tuned | **PARAM** (mode frequency ratios, decay times, amplitudes) — same PARAM-only shape as the drum synth, extends its reach to tuned percussion |
| Vector/morph (N-corner crossfade) | Prophet-VS/Wavestation lineage, Alchemy transform pad, Pigments | Medium (strong UX/AI-split payoff, §6.5) | Medium — one crossfade engine over N already-built voices/presets, no new oscillator math | **PRESET** (agent authors the corners) driven by a **PARAM** (XY/point position) |
| Phase distortion (CZ-style DCW) | Casio CZ lineage | Low-Medium (mostly superseded by wavetable warping, which is strictly more flexible) | Low | **PARAM** (DCW amount) — listed for completeness; not competitive with wavetable warp for the same build cost |

### 7.2 Richness modifiers (apply to any engine, including PolySynth as-is)

| Feature | Who has it | Payoff | DSP complexity | LLM drive |
|---|---|---|---|---|
| Unison / detune / voice spread | Nearly every modern synth; Sylenth1's reputation is built on it alone | **High** | Medium — restructures one "voice" into N sub-voices with phase-randomized starts; no per-sample coefficient recompute needed beyond what already exists, but touches the `Voice` struct/allocation shape | **PARAM** (voiceCount, detuneCents, stereoSpread) |
| Oscillator drift / analog imperfection | u-he Diva | Medium-High | Low-Medium — a slow per-voice random walk added once per render block, not per sample; does not need full audio-rate modulation | **PARAM** (driftAmount, one knob) |
| Sub-oscillator | Nearly every analog-modeled synth | Medium | Low — one more oscillator per voice, fixed ratio, own level | **PARAM** (subLevel, subOctave, subWaveform) |
| Noise layer | Nearly every synth; essential to drum synthesis (§4) | Medium-High | Low | **PARAM** (noiseLevel, noiseColor) |
| Velocity/key tracking on cutoff | Nearly every subtractive synth | Medium-High | Low — a scalar formula applied at note-on, not a per-sample cost | **PARAM** (velToCutoff, keyToCutoff amounts) |
| Per-voice randomization (pan/detune/cutoff jitter) | Common in premium synths | Low-Medium | Low | **PARAM** (jitterAmount) |
| Filter self-oscillation headroom | Any SVF/ladder at high Q; ours already has the SVF, just capped at Q 10 | Medium | **Trivial** — extend `resonanceRange`'s mapping | **PARAM** (extend existing `resonance` range) |
| Saturation/drive in the filter path | Diva, most "warm" synths | High | Low — one `tanh`-style waveshaper, stateless per sample | **PARAM** (driveAmount) |
| Envelope curve shape (exp vs. linear) | Every serious synth; ours is linear-only today | Medium | Low — changes the per-sample step *formula*, not the once-per-generation recompute contract | **PARAM** (curve exponent or a named-curve enum) |
| Filter envelope (2nd ADSR → cutoff) | Every serious synth | High | **High** — this is the one that actually breaks the "recompute only on generation change" contract: cutoff must move every sample (or block) while a note sounds, which today's `tan()`-based coefficient derivation is not cheap enough to do per sample | Nominally **PARAM** (a second ADSR's 4 numbers) but *architecturally* a **MODULATOR** — see §8's block-rate compromise |
| LFO(s) / general mod matrix | Vital, Surge (12 LFOs), Massive X | High | **High** — same render-path-contract break as above, generalized to arbitrary sources/destinations; this is real new render-thread work, not a bigger struct | **MODULATOR** — source, destination, depth, shape; the expensive one, by design |
| Macro controls (1 knob → N destinations) | Massive X, Meld | High for *agent* control specifically (one lever an agent can name and reason about, "brightness") | Medium — needs the mod-routing data structure even if each destination itself stays coefficient-per-generation | **MODULATOR** (a fan-out routing table), but drivable with a single scalar once authored — cheapest MODULATOR to build first |
| Scripted modulator (Lua/formula) | Surge XT | Medium (power-user feature for humans; potentially high for agents, §6.6) | Medium-High — needs an embedded interpreter and a sandboxed, RT-safe evaluation boundary | **MODULATOR**, authored as a short script an agent emits directly — the most "agent-native" primitive on this whole table |
| Generative/evolving step sequencer for modulation | Pigments | Medium | Medium — a step list evaluated at block or note rate, not audio rate | **MODULATOR**, authored as an explicit step array — cheap for an agent to emit exactly (no ambiguity like an LFO shape) |

### 7.3 Drum-specific detail (rows folded into 7.1's "Drum synth" but broken out for the DSP recipe)

| Feature | Who has it | Payoff | DSP complexity | LLM drive |
|---|---|---|---|---|
| Pitch envelope on a sine (kick) | 808 lineage | High | Low — a second, fast, independent decay applied to oscillator frequency | **PARAM** (pitchEnvAmount, pitchEnvDecay) |
| Noise-through-bandpass (snare/hat body) | 909 lineage | High | Low-Medium — noise generator + one bandpass filter + its own envelope | **PARAM** (noiseBandpassHz/Q, noiseDecay) |
| Ring-modulated oscillator cluster (metallic hats/cymbals) | 909 lineage | Medium-High | Medium — 6 oscillators + ring-mod stage + filter, still all per-generation/per-note, no per-sample recompute needed since it's a one-shot | **PARAM** (ringModHz, metallicAmount) |
| Transient/click layer | Universal in commercial drum synths | High (perceived "punch") | Low — a very short secondary noise/impulse burst, independent envelope | **PARAM** (clickAmount, clickDecay) |

## 8. Ranked shortlist

**If we can only build 2–3 new instruments, in this order:**

1. **Drum/percussion synth** (`.drumSynth`). Highest payoff-to-complexity ratio on the entire
   survey: every technique in §4/§7.3 is low-complexity, PARAM-only, and fits inside the *existing*
   per-generation-recompute render contract without modification (a one-shot voice's pitch/amp
   envelopes are just two more per-sample ramps, exactly like the ADSR PolySynth already runs).
   No sustain-pedal interaction, no voice-stealing subtlety beyond "retrigger." It is also the
   engine family where "describe it in plain language" (§4's "higher click, longer boom") maps to
   scalar params most directly of anything researched — the ideal first proof that an agent can
   drive a synthesis engine well.
2. **FM/PM synth** (`.fmSynth`), 2–4 operators, ~6 fixed algorithms, one feedback scalar per
   operator, per-operator envelopes, one shared filter stage (Ableton Operator's shape, §5). Low DSP
   complexity — phase-modulated sine cores cost about what our current sine waveform path already
   pays per sample, and a lookup-table sine keeps that cheap at 2–4 operators — and it is the engine
   where an agent has a *structural* reasoning advantage over a human sound designer (§6.3) — the
   clearest "AI control" story of any engine surveyed, which matters for a product whose stated edge
   is AI control.
3. **Wavetable synth** (`.wavetableSynth`), position-scan only for v1 (defer read-modes,
   spectral warping, granular/additive hybrids). Highest payoff of the "modern default" sound
   category, but correctly ranked third because it is the one that needs a genuinely new asset
   pipeline (wavetable frame format, at minimum an importer; ideally an agent-side table generator
   — §6.1's "compose a wavetable procedurally" is the differentiator worth the asset-pipeline cost).

**Before any of the above, or in parallel at near-zero marginal cost:** a **PolySynth richness
pass** — unison, sub-oscillator, noise layer, oscillator drift, filter self-oscillation headroom,
filter-path saturation, and non-linear envelope curves (the top rows of §7.2 marked Low/Medium
complexity). None of these need a new `InstrumentDescriptor.Kind`, none of them break the
per-generation-recompute contract, and collectively they close most of the literal "thin preset"
gap named in the brief for the instrument we already ship. This should happen regardless of which
new instrument(s) get built next, and is the cheapest way to make PolySynth stop sounding like a
placeholder.

**Deliberately deferred:** general LFO/mod-matrix and filter envelopes (§7.2's High-complexity
rows) — not because they're low-value, but because they are the one category that requires an
actual render-path redesign (per-sample or per-block coefficient recomputation instead of
per-generation), and mixing that redesign into the first 2-3 new-instrument builds risks
under-scoping both. A pragmatic middle path if/when this is tackled: **block-rate modulation** —
recompute filter/pitch coefficients once per render quantum (the existing `render()` call boundary
— this report did not measure the quantum's actual sample count, so treat it as "whatever
`render()` is already called with," not a specific number) rather than only on
published-parameter-generation change. That bounds the cost (one `tan()` and a handful of multiplies
per quantum instead of per parameter edit) but has a known artifact: stepping coefficients once per
block rather than continuously produces audible "zipper" noise on fast filter-envelope attacks or
quick LFO rates, because the cutoff jumps discretely at each block boundary instead of moving
smoothly. The standard mitigation is to interpolate the target coefficient across the block (or
across smaller sub-blocks, e.g. 32–64 samples, for fast modulation) rather than snapping to it —
which is itself extra per-block (not per-sample) work, but changes the estimate for whoever scopes
this. Worth a dedicated `daw-architect`/`audio-dsp-engineer` design pass that accounts for the
interpolation cost explicitly, not something to bolt on inside a drum-synth or FM-synth build.

Granular and general additive are ranked out of the top 3 on complexity (grain scheduler; N-partial
bank) relative to payoff for a beginner-facing, simplicity-first product — both remain good
candidates for a later wave once the asset-pipeline muscle exists (built first for wavetable).

## 9. Concrete parameter surface — Drum Synth (top recommendation)

Modeled directly on `PolySynthParams`'s house convention (`Sources/DAWCore/Model.swift:2545`):
`Double` fields, `camelCase`, seconds/Hz/0...1 units, `static let ...Range: ClosedRange<Double>`
per field, an `enum` for the fixed engine choice, additive-optional so it decodes cleanly onto
existing projects.

```swift
public struct DrumVoiceParams: Codable, Sendable, Equatable {
    public enum Engine: String, Codable, Sendable, CaseIterable {
        case kick    // sine + pitch envelope + optional click transient
        case snare   // 1-2 tone oscillators + noise through bandpass
        case hat     // ring-modulated oscillator cluster + bandpass/highpass
        case tomClap // tunable single tone + noise burst (covers toms, claps, low percussion)
    }
    public var engine: Engine

    // Tone path (kick/snare/tomClap)
    public var toneHz: Double            // base/carrier pitch
    public var toneDecay: Double         // amplitude decay of the tone, seconds
    public var pitchEnvAmount: Double    // 0...1, sweep depth (0 = no pitch sweep)
    public var pitchEnvDecay: Double     // seconds — deliberately much shorter-range than toneDecay
    public var toneSaturation: Double    // 0...1, tanh drive on the tone path ("808 distortion" knob)

    // Second tone (snare body / tom overtone) — ignored by .kick/.hat
    public var tone2Hz: Double
    public var tone2Mix: Double          // 0...1

    // Noise path (snare/hat/tomClap)
    public var noiseColor: Double        // 0...1, lowpass..highpass tilt on the noise source
    public var noiseDecay: Double        // seconds
    public var noiseBandpassHz: Double   // bandpass center, snare/hat "body"
    public var noiseBandpassQ: Double

    // Ring-mod / metallic cluster (hat engine only)
    public var ringModHz: Double         // ring-mod carrier for the oscillator cluster
    public var metallicAmount: Double    // 0...1, dry vs. ring-modulated blend

    // Transient / click (any engine)
    public var clickAmount: Double       // 0...1, short impulse burst at note-on
    public var clickDecay: Double        // seconds, deliberately sub-20ms range

    public var gain: Double              // 0...1
    public var pan: Double               // -1...1

    public static let toneHzRange: ClosedRange<Double> = 20...2_000
    public static let toneDecayRange: ClosedRange<Double> = 0.01...3
    public static let pitchEnvAmountRange: ClosedRange<Double> = 0...1
    public static let pitchEnvDecayRange: ClosedRange<Double> = 0.001...0.5
    public static let toneSaturationRange: ClosedRange<Double> = 0...1
    public static let tone2HzRange: ClosedRange<Double> = 20...4_000
    public static let tone2MixRange: ClosedRange<Double> = 0...1
    public static let noiseColorRange: ClosedRange<Double> = 0...1
    public static let noiseDecayRange: ClosedRange<Double> = 0.001...2
    public static let noiseBandpassHzRange: ClosedRange<Double> = 200...16_000
    public static let noiseBandpassQRange: ClosedRange<Double> = 0.3...10
    public static let ringModHzRange: ClosedRange<Double> = 200...8_000
    public static let metallicAmountRange: ClosedRange<Double> = 0...1
    public static let clickAmountRange: ClosedRange<Double> = 0...1
    public static let clickDecayRange: ClosedRange<Double> = 0.0005...0.02
    public static let gainRange: ClosedRange<Double> = 0...1
    public static let panRange: ClosedRange<Double> = -1...1
}

public struct DrumKitConfig: Codable, Sendable, Equatable {
    public var pads: [DrumVoiceParams]   // one per MIDI note/pad slot, e.g. GM-style 8-16 pads
}
```

**Wire shape** (following the `.sampler`/`.audioUnit`/`.soundBank` precedent at
`Model.swift:1599-1627` and `ProjectStore.setInstrument` at `ProjectStore.swift:3796`, both
re-verified for this report on 2026-09-19): a sixth `InstrumentDescriptor.Kind` case `.drumSynth`
with an additive-optional `drumKit: DrumKitConfig?` payload, set wholesale (like `sampler`/`audioUnit`
today) via `track.setInstrument`. This keeps the wire-command count delta to roughly what
`.soundBank` cost in m10-n (a handful of new commands/tools, not one per parameter) — every field
above is a leaf of one JSON payload, not a separate command, so the baseline command/tool count
(215 wire commands / 220 MCP tools, measured 2026-09-04) grows by the same small, additive shape
prior instrument kinds did, not by 16-per-voice.

Every field in `DrumVoiceParams` is **PARAM** per the §6 framing — this instrument needs no
MODULATOR-class work at all, which is exactly why it is ranked first.

## 10. Actionable takeaways

- **ROADMAP:** file three new items — `PolySynth richness pass` (unison, sub-osc, noise, drift,
  saturation, envelope-curve shape, self-oscillation headroom — no new `Kind`, no render-path
  contract change), `Drum synth (.drumSynth)` using the §9 parameter surface, and `FM/PM synth
  (.fmSynth)`, 2–4 operators + fixed algorithms + feedback + per-operator envelopes. Route the
  richness pass and drum synth to `audio-dsp-engineer` first (both fit inside the current render
  contract); route the FM synth to `audio-dsp-engineer` with a `daw-architect` sign-off on the
  operator/algorithm data model before implementation (it is a new oscillator core, not a bolt-on).
  Sequence wavetable synth as a fourth item, explicitly gated on someone first designing the
  wavetable asset/import format — don't start it opportunistically.
- **ARCHITECTURE:** record the render-path-contract finding from §0/§8 as a named constraint —
  "any modulation source that must move a filter/pitch coefficient while a note sounds is a
  render-path change, not a parameter addition" — so future roadmap items (filter envelope, LFOs,
  macros) get scoped and routed correctly instead of being mis-estimated as "add a field to a
  struct." Record the **block-rate modulation** compromise (§8), including its zipper-noise
  mitigation cost, as the recommended next design spike when that work is picked up, rather than
  either skipping mod entirely or jumping straight to per-sample general-purpose modulation.
- **ARCHITECTURE / near-term, low-cost:** the closed-loop sound-matching capability named in §6.1 is
  buildable **today** from existing primitives (offline render, `instrument.probeLiveness`,
  `clip.analyze` design) — worth a short design spike of its own (`render candidate → measure →
  compare to target → adjust PARAMs → repeat`) independent of which new instrument ships first, since
  it applies to PolySynth as-is.
- **Do not build a general LFO/mod-matrix or filter envelope as part of the first 2-3 new
  instruments.** Every product surveyed that "feels rich" leans on modulation, but §0/§7.2 show it is
  the one item that changes our render-thread contract rather than extending it — scope it as its own
  milestone with its own gate, after the PARAM-only wins ship and are measured.
- **Keep AU hosting as the answer for sample-library content, not synthesis** — §1's two findings
  (unvalidated remote-view wedge risk, opaque per-instance param trees) are reasons to build our own
  synthesis engines specifically, not a general argument against hosting; nothing here contradicts
  the 2026-07-16 free-instruments survey's conclusions about content libraries.
- **License hygiene:** Surge XT and Vital are both GPLv3 (confirmed: [Surge FAQ](https://surge-synthesizer.github.io/faq/),
  [Vital GitHub](https://github.com/mtytel/vital)) — safe to *study* their DSP approach for design
  reference (as this report does), but their source may not be copied verbatim into DAW Pro's
  proprietary codebase without triggering GPL obligations. Dexed and Odin2 are the same (GPL-3, per
  the 2026-07-16 free-instruments survey) for the same reason.

## Sources

- [Vital — Spectral Warping Wavetable Synth](https://vital.audio/)
- [Vital GitHub source (GPLv3)](https://github.com/mtytel/vital)
- [Bedroom Producers Blog, Vital vs Surge (2026-06-10)](https://bedroomproducersblog.com/2026/06/10/vital-vs-surge/)
- [Vital text-to-wavetable forum thread](https://forum.vital.audio/t/text-to-wavetable-template-customization/1300)
- [Unison.audio, Xfer Serum 2 feature rundown (2025-03)](https://unison.audio/xfer-serum-2/)
- [SynthAnatomy, Serum 2 first look (2025-03)](https://synthanatomy.com/2025/03/xfer-records-serum-2-super-popular-wavetable-synth-gets-massive-free-update.html)
- [Sonic Weaponry, Serum 2 full feature breakdown](https://sonic-weaponry.com/blogs/free-production-tutorials-and-resources/serum-2-released)
- [Surge Synth Team — surge-synthesizer.github.io](https://surge-synthesizer.github.io/)
- [Surge XT FAQ (GPL3 licensing)](https://surge-synthesizer.github.io/faq/)
- [Surge XT source (GitHub)](https://github.com/surge-synthesizer/surge)
- [sunsetsilencio, Exploring Surge XT](https://www.sunsetsilencio.com/blog/exploring-surge-xt/)
- [Righto, Yamaha DX7 chip reverse-engineering pt. 4 (algorithms)](https://www.righto.com/2021/12/yamaha-dx7-chip-reverse-engineering.html)
- [ajxs.me, Yamaha DX7 Technical Analysis](https://ajxs.me/blog/Yamaha_DX7_Technical_Analysis.html)
- [Ableton, Operator](https://www.ableton.com/en/packs/operator/)
- [Ableton, Wavetable](https://www.ableton.com/en/packs/wavetable/)
- [Ableton, Meld (Live 12 bi-timbral synth)](https://www.ableton.com/en/blog/meld-a-look-at-live-12s-new-bi-timbral-synth/)
- [musicproductionwiki, Ableton Operator review](https://musicproductionwiki.com/articles/ableton-operator-review)
- [Native Instruments, Massive X details](https://www.native-instruments.com/en/products/komplete/synths/massive-x/details/)
- [Arturia, Pigments sound design](https://www.arturia.com/products/software-instruments/pigments/sound-design)
- [Spectrasonics, Omnisphere features](https://www.spectrasonics.net/products/omnisphere/omnisphere-features.php)
- [Spectrasonics, Omnisphere manual — Granular](https://support.spectrasonics.net/manual/Omnisphere2/25/en/topic/layer-page-oscillator-page29)
- [u-he, Diva product page](https://u-he.com/products/diva/)
- [Syntorial, u-he Diva highlight](https://www.syntorial.com/highlights/uhe-diva/)
- [musicproductionwiki, Sylenth1 review (2026)](https://musicproductionwiki.com/articles/sylenth1-review)
- [MusicRadar, ultimate guide to Alchemy](https://www.musicradar.com/news/ultimate-guide-alchemy-logic-pro)
- [MusicRadar, Sample Alchemy how-to](https://www.musicradar.com/how-to/logic-sample-alchemy)
- [Kilohearts, Phase Plant](https://kilohearts.com/products/phase_plant)
- [Kilohearts docs, Phase Plant](https://kilohearts.com/docs/phase_plant)
- [Wikipedia, Phase distortion synthesis](https://en.wikipedia.org/wiki/Phase_distortion_synthesis)
- [Wikipedia, Korg Wavestation](https://en.wikipedia.org/wiki/Korg_Wavestation)
- [Reverb.com, 10 types of synthesis explained](https://reverb.com/fr/news/10-types-of-synthesis)
- [Stanford, Sound and Music — the Karplus-Strong algorithm](http://crypto.stanford.edu/~blynn/sound/karplusstrong.html)
- [Wikipedia, Digital waveguide synthesis](https://en.wikipedia.org/wiki/Digital_waveguide_synthesis)
- [Wikipedia, Physical modelling synthesis](https://en.wikipedia.org/wiki/Physical_modelling_synthesis)
- [McGill, Nord Modular book — Percussion Synthesis chapter](https://cim.mcgill.ca/~clark/nordmodularbook/nm_percussion.html)
- [Perfect Circuit, Kick drum synthesis with Eurorack modules](https://www.perfectcircuit.com/signal/kick-drum-synthesis)
- [Unison.audio, What is an 808 drum](https://unison.audio/808-drum/)
- [ModWiggler forum, 808→909 hi-hat processing](https://modwiggler.com/forum/viewtopic.php?t=259594)
- [Native Instruments blog, Granular synthesis: a beginner's guide](https://blog.native-instruments.com/granular-synthesis/)
- [Sound on Sound, Granular synthesis: a practical introduction](https://www.soundonsound.com/techniques/granular-synthesis-practical-introduction)
- [CTAG — Creative Text-to-Audio Generation via Synthesizer Programming (ICML 2024, arXiv:2406.00294)](https://arxiv.org/abs/2406.00294)
- [Syntheon — synthesizer parameter inference, supports Vital (GitHub)](https://github.com/gudgud96/syntheon)
- [InverSynth — Deep Estimation of Synthesizer Parameter Configurations (arXiv:1812.06349)](https://arxiv.org/abs/1812.06349)
- [DiffMoog — a Differentiable Modular Synthesizer for Sound Matching (arXiv:2401.12570)](https://arxiv.org/html/2401.12570v1)
- [Modulation Discovery with Differentiable DSP (arXiv:2510.06204)](https://arxiv.org/abs/2510.06204)
- [Learning to Solve Inverse Problems for Perceptual Sound Matching (arXiv:2311.14213)](https://arxiv.org/pdf/2311.14213)

### Internal sources (codebase / prior research, direct reads)

- `Sources/DAWEngine/Instruments/PolySynthInstrument.swift`
- `Sources/DAWCore/Model.swift:2545` (`PolySynthParams`), `:1599-1627` (`InstrumentDescriptor.Kind`,
  re-verified 2026-09-19)
- `Sources/DAWCore/ProjectStore.swift:3796` (`setInstrument`, re-verified 2026-09-19)
- `docs/ARCHITECTURE.md` (Instrument sections)
- `docs/research/2026-07-16-free-instruments.md`
- `docs/research/design-au-parameter-surface.md`
- `docs/research/design-m10n-instrument-library.md`
- `docs/research/m23av-routeb-feasibility-probe.md`
