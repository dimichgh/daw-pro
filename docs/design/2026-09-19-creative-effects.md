# The creative effects suite — design and frozen contract (M40)

**Author:** `daw-architect`, 2026-09-19.
**Status:** §6 and §7 are **normative**. Implementers follow them verbatim; a deviation is made by
amending this document in a commit that says so, not by code that quietly differs.
**Prerequisite reading, in this order:** `docs/design/2026-09-19-modulation-layer.md` §6.2, §7.2, §7.3
(the frozen depth law and per-param verdicts — this document is built on top of them and does not
re-open them), then `docs/research/2026-09-19-plugin-program-inventory.md` §7–§11 (the verified cost
base). Everything else is claims.

---

## 0. Source state at the time of writing — read this before checking my citations

An `audio-dsp-engineer` is **concurrently implementing the modulation layer** (m39-e), touching
`Sources/DAWControl/Commands.swift`, `Sources/DAWCore/ProjectStore.swift` and
`Sources/DAWEngine/Automation/AutomationRenderer.swift`, and adding `mod.*` verbs. Branch
`m23-wip-2026-08-10`, working tree dirty.

**What I read, and in what state I saw it:**

| file | what I verified, first-hand | state |
|---|---|---|
| `Sources/DAWEngine/Effects/ChorusEffect.swift` | the whole file, 245 lines | **pre-m39-e** — no `mod` symbols present |
| `Sources/DAWEngine/Effects/EffectRendering.swift` | the whole protocol, 141 lines | **pre-m39-e** |
| `Sources/DAWEngine/Effects/EffectFactory.swift` | the whole file, 87 lines | **pre-m39-e** — 11 kinds + `.audioUnit` |
| `Sources/DAWEngine/Effects/EffectChainProcessor.swift` | `processActive`, `renderCrossfade`, both `process` overloads | **pre-m39-e** |
| `Sources/DAWEngine/Automation/AutomationRenderer.swift` | `apply`, `storeEffectParams` signatures, `quantumStart` | ⚠️ **possibly mid-edit** — I read it by symbol, and I cite it **by symbol, never by line** |
| `Sources/DAWEngine/Effects/ChainHostAU.swift` | grep only, for the render-block closure's `timestamp` plumbing | **pre-m39-e** |
| `Sources/DAWCore/Effects.swift` | `EffectDescriptor.Kind`, `EffectParamSpec`, `ReverbParams`, `DelayParams`, `ChorusParams` | **pre-m39-e** |
| `Sources/DAWCore/ParamCurve.swift` | the whole file, 139 lines | **m39-a, shipped** |
| `Sources/DAWEngine/PlaybackGraph.swift` | **added at review** — `buildRollSchedule`, `publishMasterAutomation`, and the strip publish path's `requireAnchor` local. Grep + one 70-line window; never read whole (it is one of the watchdog files) | ⚠️ **MID-EDIT by m39-e** — `requireAnchor` is m39-e's own work, landing as I read it. Cited **by symbol**. |
| `Sources/DAWEngine/Automation/AutomationSchedule.swift` | **added at review** — `build`/`buildLoopUnrolled` `requireAnchor:` parameter and its guard + doc comment | ⚠️ **MID-EDIT by m39-e.** Cited by symbol. |

**Four facts I established myself that no input document contained**, because the DJ/loop report
named the first as the question it could not answer and the design turns on all of them:

1. ⭐⭐ **`EffectRendering.process(buffers:frameCount:)` receives NO transport position, and neither
   does `EffectChainProcessor.process(bufferList:frameCount:key:)`.** Both overloads take only a
   buffer list, a frame count and an optional key. The `AudioTimeStamp` exists one level up — the
   render-block closure in `ChainHostAU` has it and hands it to `AutomationRenderer.apply` and
   `.storeEffectParams`, which convert it to a schedule-relative `Int64` through the private
   `quantumStart(of:timestamp:)`. **So `docs/research/2026-09-19-dj-loop-fx.md` §9.6's option (b) —
   "a self-contained transport-aware sequencer inside the effect's own `process()`" — is not free
   today.** It needs a protocol widening. §4.3 prices it and freezes its shape.
2. ⭐⭐ **Sends are POST-fader** (`Sources/DAWCore/Model.swift:1467`, verbatim: *"One post-fader send
   from a source track into a bus (M4 i)"*, corroborated at `Sources/DAWEngine/PlaybackGraph.swift:149`
   — *"Inserts are pre-fader; meters read post-FX; post-fader sends carry…"*). This single fact is
   what makes the trance gate buildable with **zero new DSP** (§3.2).
3. ⭐ **`ChorusEffect` already runs a per-sample oscillator inside `process()`** — `lfo += phaseIncrement`
   at `ChorusEffect.swift:239`, with `phaseIncrement = 2·π·rateHz / sampleRate` at `:164`. The DJ
   report's "ring modulation **requires its own audio-rate oscillator primitive** … budget for that
   explicitly" is therefore **retired**: the primitive ships, in production, RT-safe; an audio-rate
   carrier is that same accumulator with a larger increment. It is not a budget item (§2, row R).
4. ⭐⭐ **Found at REVIEW, and it made D8 cheaper: an anchor-only, point-less `AutomationSchedule`
   already publishes.** `AutomationSchedule.build`/`buildLoopUnrolled` carry a `requireAnchor:` flag
   whose doc comment says it exists because *"a MODULATION ROUTE has no points but still needs the
   schedule's ANCHOR"*; the strip publish path computes it as
   `modulatesVolume || modulatesPan`. **I had written D8's cost up as "build a publish-side
   predicate"; the predicate exists and needs one term added.** §4.3 carries the corrected number.
   ⚠️ This is m39-e's in-flight work — re-verify it has landed before quoting the price.

⭐ **Item IDs are SETTLED: this work files into M39 as `m39-i … m39-ab`, contiguously in ranking
order.** I initially minted `m40-*` on the strength of *"`m40-` returns zero hits in the roadmap"* —
a true fact answering the wrong question. **M39's title already claims this scope** (*"a modulation
layer, creative FX, synthesis engines, and presets"*), so a new milestone would duplicate a home.
Ruled by the orchestrator 2026-09-19; see §11.0.2 for the allocation table and the verification.

---

## 1. Decisions at a glance

| # | Decision | The rejected alternative, and why it loses |
|---|---|---|
| D1 | **The trance gate / tremolo / auto-pan family ships as PRESETS + DOCS + DEMOS, not as effect kinds.** m39-e's `ModulationStage` evaluates a source **per sample** on the `.volume`/`.pan` path and delivers closed-form, seek-exact edges. A `.stepGate` effect kind would be a second, worse implementation of a thing being built this week. | *(a) A `.stepGate` effect kind* — loses because it re-implements a shipped mechanism, pays 6 switch sites, and its edges would ride the **quantum-rate** effect-param path (±10.7 ms, inconsistent), which is strictly worse than the per-sample path it would be sitting next to. *(b) Wait for the effect-param path to get per-sample ramps* — priced and **declined** by the modulation design §6.3; do not re-open. |
| D2 | **`.djFilter` is the first new kind built.** A real resonant bipolar single-knob multimode filter. No tempo sync ⇒ **not gated on m39-d** ⇒ it is the only high-identity item that can ship immediately. | *(a) Extend `EQParams` with resonance* — loses: `EQParams` is at 22 params with frozen positional slots, its filters are Butterworth cascades with no Q control, and the DJ filter's whole identity is ONE knob with a bipolar law, which an 8-param EQ cannot present. *(b) Ship the FDN reverb first* — loses on time-to-audible: reverb is weight L, the filter is M, and the user named DJs. |
| D3 | **`.hallReverb` — an 8-line FDN, Householder mixing, per-line two-band absorption, small length modulation — ships as a NEW ADDITIVE KIND. `.reverb` is LEFT ALONE and DOCUMENTED HONESTLY, not deprecated.** | *(a) Fix `.reverb`* — structurally impossible: `roomSize` is frozen at automation slot 0 forever and comb lengths are compile-time constants. *(b) Deprecate `.reverb` in prose* — loses: it creates a second-class effect agents will avoid while real projects still render through it, and Freeverb's small-bright-room character is genuinely useful. Honest `note` text costs nothing and breaks nothing. |
| D4 | **A Dattorro plate becomes a `topology` MODE on `.hallReverb` if and only if its delay-line budget fits inside the FDN's prepare-time allocation.** The decision rule is frozen here; the decision itself is taken at plate-build time, **on a measurement**. | *(a) Decide now that it is a mode* — loses: a mode whose state does not fit forces either a render-thread reallocation (forbidden) or a permanently oversized allocation for every hall user. *(b) Decide now that it is its own kind* — loses: pays 6 switch sites for what is probably the same machinery. |
| D5 | **Exactly ONE primitive is extracted in this milestone: `InterpolatedDelayLine`.** The `Oversampler` API is **declared here and built with its first caller**, extracted only when the second arrives. The capture ring buffer is **deferred with the effects that need it**. | *(a) Extract all three up front* — loses to the one-home law's own second edge: a home built for one caller is the too-narrow home that gets bypassed. *(b) Extract none* — loses: the chorus tap is the exact code three requested features need, and its write-head-crossing guarantee is the subtle condition a fresh implementation gets wrong. |
| D6 | **The `steps: [Double]` array is NOT an effect parameter. It already exists, frozen, as `stepSequencer.steps` on the modulation SOURCE surface** (`mod.addSource` takes a `params` OBJECT backed by a per-kind struct, not the numeric `EffectParamSpec` table). Zero new machinery, zero ruling needed. | *(a) 32 indexed scalars `step0…step31`* — loses: 32 automation slots frozen forever for a pattern that wants to change length, and `fx.describe` becomes unreadable. *(b) A new pattern-typed param kind* — loses: invents a second param surface to solve a problem the modulation contract already solved. |
| D7 | **A boolean/one-shot `engage` is a `0…1` numeric param with `Modulatable: refused`, reason `discrete`, driven by an `automation.addLane` `hold`-curve lane.** Quantum-accurate (±10.7 ms), on the existing surface, zero new machinery. A **sample-accurate** engage requires the position primitive (D8) and is deferred with it. | *(a) A `fx.trigger` verb* — loses: hidden render-thread state, not reproducible offline, and the modulation design already rejected `mod.trigger` for exactly this reason. *(b) A new event schedule* — loses: m39-e §3.2 dissolved the need for one and a second schedule re-creates it. |
| D8 | **The position-delivery API shape is FROZEN NOW even though nothing in this milestone uses it** — an additive, default-inert `EffectRendering` method called from the seam that already holds the timestamp. Freezing it now is what stops the beat-repeat spike re-litigating it. | *(a) Leave it open* — loses: the DJ report already spent a section unable to answer it, and the next spike would spend another. *(b) Build it now* — loses: nothing in the ranked top tier needs it, and an unused API is an unverified API. |
| D9 | **CUT built-in ducking from `HallReverbParams`.** The orchestrator **rendered** the reverb-bus + sidechained-compressor topology and measured it working (0.5 LU cleared → 1.6 / 1.2 / 2.7 LU as ducking deepened). Shipping `duckAmount` would be a second, worse implementation of a measured-working capability, and would additionally require `KeyableEffectRendering` conformance plus a widening of the store's sidechain whitelist. | *(a) Build `duckAmount` anyway because it is "one knob"* — loses to the measurement. *(b) Widen the `ProjectStore` sidechain whitelist so reverb can be keyed* — loses: the inventory verified that the guard is not what makes ducking work; the DSP is, and it does not exist. |
| D10 | **`shimmerMix` / `shimmerIntervalSemitones` are CUT from `HallReverbParams` v1.** Shimmer is a pitch shifter inside a feedback loop. The pitch shifter does not exist; `docs/research/2026-07-05-time-stretch-library-evaluation.md` already picked signalsmith-stretch for the offline case and its real-time mode has never been exercised here. | *(a) Ship a cheap crossfaded-varispeed octave-up* — loses: it is a third delay-line resampler with its own artefacts, built inside the most CPU-sensitive loop in the suite, to serve one parameter. Defer to the pitch-shifter item where it is one caller among six. |
| D11 | **No composite `fx.applyGesture` verb in this milestone.** Named gestures ship as **skill prose plus demo specs** — a documented call sequence, not a new verb. | *(a) Ship `fx.applyGesture`* — loses **for now** on scope, not on principle: it is consistent with one-command-surface if it converges on `ProjectStore`, but every gesture it would bundle is either already a two-call sequence (`mod.addSource` + `mod.addRoute`) or an effect that does not exist yet. Re-open it once three gestures exist to bundle. Filed as `m39-v`. |

---

## 2. The ranked, costed build order

**The cost base, restated so it is not conflated** (inventory §3, measured off `bitCrusher`): a new
effect kind is **6 mandatory switch sites** — `EffectFactory.swift`, `EffectEditorModel.swift`,
`MixerModel.swift`, `Effects.swift`, `ProjectStore.swift`, `Commands.swift` — inside a **29-file blast
radius**. The 6 is the irreducible compiler-forced edit set. The 29 is mostly tests using a kind as a
fixture and docs mentioning it; most need no change for a *new sibling* kind. **Quoting 29 as the cost
of a new effect is wrong by roughly 5x.** Beyond the 6: the DSP, a UI editor surface, a control
command, an MCP tool, tests both sides, and docs.

Weights below: **S** ≈ 1 agent-day of DSP on top of the 6 sites · **M** ≈ 2–4 · **L** ≈ a week+.

### 2.1 The ranking

| rank | candidate | payoff | cost | m39-d gated? | verdict |
|---:|---|---|---|---|---|
| — | **Ducked reverb** | high | **ZERO** | no | ⭐ **ALREADY POSSIBLE — RENDERED AND MEASURED.** Preset + docs + a usage warning. §3.1 |
| — | **Filter sweep (no resonance)** | med | **ZERO** | no | ⭐ **ALREADY POSSIBLE TODAY** via `automation.addLane` on `eq.lowPassFreq`. Honest about what it lacks. §3.1 |
| — | **Tremolo · auto-pan · free-Hz gater** | high | **ZERO beyond m39-e** | no | ⭐ **SHIPS WITH m39-e.** Presets + demos only. §3.2 |
| — | **Tempo-synced trance gate** | very high | **ZERO beyond m39-e + m39-c** | ⛔ **YES** | ⭐ **NO NEW EFFECT KIND.** Preset + docs. Gated. §3.2 |
| **1** | **`.djFilter`** — bipolar single-knob resonant multimode | very high | **M** | **no** | ⭐ **BUILD FIRST.** Highest identity-per-cost, and the only high-identity item with nothing in front of it. §6.1 |
| **2** | **`.flanger`** | high | **S** | no | **BUILD SECOND** — it is the proof that `InterpolatedDelayLine` (§4.1) is a real home, on the cheapest possible caller. §6.3 |
| **3** | **`.hallReverb`** — 8-line FDN | very high | **L** | no | ⭐ **BUILD THIRD.** The single largest quality win in the suite; the user named reverbs. §5, §6.2 |
| **4** | **`.ringMod`** | high | **S** | no | The user named "frequency modulation". Blocker **retired** — the per-sample oscillator is `ChorusEffect.swift:239`. §6.4 |
| **5** | **`.stereoWidth`** (mono-maker + M/S width) | high | **S** | no | ⚠️ **ADOPT `m23-dj`, do not mint beside it.** Mono compatibility is that item's acceptance test. |
| **6** | **`.tapeDelay`**, free-ms mode only | high | **M** | free-ms **no** · synced ⛔ **YES** | Needs `InterpolatedDelayLine`; `.delay` is integer-sample-only and structurally cannot wow (verified). Ship free-ms first; sync is a later append. |
| **7** | **`.phaser`** | med-high | **S-M** | no | Allpass chain + the same in-effect LFO. Cheap once `.flanger` has proven the pattern; lower identity than the filter. |
| **8** | **`.transientShaper`** | high | **M** | no | ⚠️ **Price the DETECTOR, not the shaper.** Verified: `TransientAnalyzer` is offline, file-in, allocates freely — **not reusable under any refactor short of a rewrite**. The gain stage is trivial. |
| **9** | **`.freqShifter`** | med-high | **M-L** | no | Genuinely new: a Hilbert (IIR allpass-pair) network. Iconic but narrow; below the transient shaper on breadth. |
| **10** | **`.clipper` + `Oversampler`** | med (high for mastering) | **M** | no | Corrective, not performance. Its real content is the `Oversampler` (§4.2), which Saturator v2 also wants. Build the two adjacently or neither. |
| **11** | **Saturator v2** (oversampled, asymmetry, flavour) | med | **M** | no | Additive optionals on the shipped `SaturatorParams`; the file's own comments already scope it as owed. Second `Oversampler` caller ⇒ this is when it gets extracted. |
| **12** | **De-esser** (a `.compressor` mode) | med | **S-M** | no | Corrective. Sidechain plumbing already ships. |
| — | **Dynamic EQ / multiband** | high | **L** | no | ⚠️ **ADOPT `m23-cl`** — already filed, already carries "requires a design spike before build commitment". Do not mint beside it. |
| — | **Beat repeat · tape stop · vinyl brake · backspin · half-time** | very high | **L + new infra** | ⛔ **YES** | **DEFERRED to their own spike (`m39-u`).** Two blockers, both named: the capture ring buffer (§4.3) and position-in-`process()` (D8). §10.1 |
| — | **Granular freeze** | med-high | **L** | yes | **DEFERRED.** A grain scheduler is a different primitive again from the capture buffer; do not let one spike absorb both. §10.2 |
| — | **Shimmer · pitch shifter · harmonizer · formant** | high | **L** | no | **DEFERRED to the pitch-shifter item.** Do not re-litigate the engine choice: `2026-07-05-time-stretch-library-evaluation.md` picked signalsmith-stretch; what is unexercised is its real-time `splitComputation` mode. §10.3 |
| — | **Isolator EQ (kill switches)** | med | **S** | no | **DEFERRED, and it is an `EQParams` APPEND, not a kind** — steeper slopes + a full-kill floor. Cheap, unglamorous, do it when someone asks. |

### 2.2 The three things this ranking says that the reports do not

- ⭐ **Four of the five highest-payoff items in the whole domain cost no new effect kind at all.**
  Ducked reverb is rendered-and-measured today; the filter sweep works today at reduced quality;
  tremolo, auto-pan and the trance gate fall out of m39-e's `.volume`/`.pan` path. The DJ report ranks
  the trance gate #1 *to build*; the honest answer is that it is #1 *to document*. This is the same
  shape as M32, where the engine turned out already capable and the milestone halved on measurement.
- ⭐ **The DJ filter, not the trance gate, is the right first BUILD** — because it is the highest-identity
  item with **no gate in front of it**, while every rhythmic item is behind m39-c and m39-d.
- ⚠️ **"Ring mod needs an audio-rate oscillator primitive" is retired by citation, not by argument.**
  `ChorusEffect.swift:239`. One accumulator, already RT-safe, already shipping.

---

## 3. Tier 0 — what we can already do, split by what it depends on

⚠️ **This section is split by DEPENDENCY STATE, not lumped as "already possible", because m39-e is
being implemented right now and is not shipped.** Conflating "works today" with "works when the thing
being written this week lands" is how a demo gets promised against code that does not exist.

### 3.1 Possible TODAY, on the shipped tree

#### ⭐ Ducked reverb — RENDERED AND MEASURED, not inferred

The orchestrator built kick + reverb-bus + sidechained compressor and rendered it. **Measured on the
isolated reverb-bus stem: momentary-loudness swing 0.5 LU with the sidechain cleared (the positive
control) → 1.6 / 1.2 / 2.7 LU as the ducking deepened.** The capability is real and needs no code.

⚠️ **And the same measurement found the thing that makes it a documentation problem rather than a
solved one: in the FULL MIX the effect vanishes** — every variant read ~1 LU and the ducked variants
were no higher than the control, because the reverb bus sat ~11 dB under the mix. **The feature works;
the usage is what makes it audible.** So the deliverable is not "a reverb that ducks", it is a preset
plus a warning an agent will actually hit:

> **Ducking a reverb only reads if the reverb is loud enough to be heard ducking.** At a send level
> ~11 dB under the mix the tail's level swing is below the mix's own variation. Raise the send, or
> solo the bus to hear it, or use a shorter/brighter tail so the duck reads as rhythm rather than as
> level.

**Deliverable (`m39-i`, weight S):** a `mixer.applyPreset` entry, the warning above in the MCP tool
description for `fx_set_sidechain`, one line in the wire-reference skill, and the demo spec in §9.4.
**No DSP. No new kind. No wire verb.**

#### Filter sweep — works today, and it is worth being precise about what it lacks

`EQParams` carries `lowPassFreq` and `highPassFreq` (with `lowPassEnabled` / `highPassEnabled`), and
`automation.addLane` exists on the wire. **So a filter sweep is drawable today.** What it is not:

- **No resonance.** The slopes are Butterworth 12/24 dB/oct with no Q control. The DJ-filter squeal
  at the top of a sweep is exactly the resonance that is missing.
- **No single knob.** A bipolar HP→bypass→LP sweep needs two lanes moving in opposition, which is
  not a gesture an agent will discover or a user will enjoy.
- **`warned`, not `yes`, under the modulation contract** — `eq`'s 14 continuous params have **no
  smoothing anywhere** and recompute 4 RBJ sections at the quantum boundary (modulation design §6.2).
  A fast automated sweep on `eq.lowPassFreq` will zipper. This is the ONLY built-in family where
  zipper genuinely bites, and it is exactly the family the sweep lands on.

**So "we already have a filter sweep" is true and is not an argument against `.djFilter`** — it is the
argument *for* it, made concrete: the missing pieces are resonance, one knob, and internal smoothing.
**Deliverable: one honest paragraph in the skill (`m39-j`, weight S).**

#### ⛔ Echo freeze is NOT already possible — the range stops short

`DelayParams.feedbackRange` is `0...0.95` (`Sources/DAWCore/Effects.swift:599`, read directly). A
freeze/echo-out needs feedback at or fractionally above **1.0** so the repeats sustain instead of
decaying. **At 0.95 the tail dies ~0.45 dB per repetition — audible decay, not a freeze.**

The fix is a range widening, and it is small but **not free**, so its risk is named here rather than
discovered: any existing test that sets feedback above 0.95 and asserts the 0.95 clamp reddens, and a
feedback of exactly 1.0 with a self-keyed filtered loop is a **marginally stable** structure — the
existing `highCutHz` in the feedback path is what keeps it from ringing forever, so the widened
ceiling must be paired with a documented statement that `highCutHz` is load-bearing at high feedback,
not decorative. **Filed as `m39-k`, weight S, route `audio-dsp-engineer`. Do not describe echo freeze
as shipping until this lands.**

⚠️⚠️ **ERRATUM E11, 2026-09-19 — m39-k SHIPPED AT `0...0.999`, NOT `0...1.0`, AND TWO SENTENCES
ABOVE ARE WRONG ON A MEASUREMENT.** (Full entry, with the tables:
`2026-09-19-creative-effects-errata.md` §E11.) Both corrections came out of rendering the thing rather than reasoning
about it, and both are pinned by `Tests/DAWEngineTests/EchoFreezeTests.swift`:

- **"a freeze needs feedback at or fractionally above 1.0" — no.** At exactly 1.0 this loop does not
  merely become "marginally stable", it **diverges without bound on any input it cannot lose**. A DC
  offset of 0.1 into a 10 ms delay measured **9.66 / 96.97 / 193.94 / 290.94** after 1 / 10 / 20 /
  30 s — a straight line, steps constant to three figures, no ceiling. At **0.999** the same input
  settled at **94.56** against the predicted 1/(1−f)·0.1 = 100, and 0.999 is a freeze by any musical
  measure: 0.0087 dB per repeat, a 350 ms tail **3.19 dB down after 110 seconds**. The ceiling is
  therefore the largest value that still cannot run away. ⚠️ Widening is backward-compatible and
  narrowing is not, so `0...1.0` would have been a one-way door onto an unbounded structure.
- **"the existing `highCutHz` is what keeps it from ringing forever" — half true, and the false half
  is the safety half.** The loop filter is a one-pole low-pass whose gain at DC is **exactly 1 at
  every setting**, so it supplies *no* stability margin: the 1.0 divergence above was measured at
  `highCutHz` 500, the most damped setting there is. What `highCutHz` really does at a freeze-grade
  feedback is set **how long the tail lasts** — measured on a 350 ms delay at 0.999, a tail was
  3.19 dB down after 110 s at 20 kHz and **gone in about 20 s at 500 Hz**. That relationship is now
  in the param's own `note`, with those numbers.
- **No discrete `freeze` affordance was added**, and the measurement is why: at the ceiling the
  continuous knob already holds (−0.0175 dB/s on the 220 Hz component measured at 350 ms), so a boolean would duplicate
  "feedback at maximum" while spending a positional automation slot that is append-only forever
  (§6.0). The thing a hardware freeze adds that a knob cannot — muting the loop's INPUT — is already
  reachable as "put the delay on a bus and pull the send to 0", which is what the note now tells
  people to do.

### 3.2 Possible when m39-e LANDS AS DESIGNED — no further work

These need **nothing from this milestone but a preset, prose and a demo**. They are here so nobody
builds an effect kind for them.

**Why they are free, in one sentence:** m39-e's `ModulationStage` takes over `.volume` and `.pan` and
evaluates the source **PER SAMPLE** — not per quantum — so a square or stepped source on `.volume` gets
**per-sample edges with no block-rate quantisation at all** (modulation design §9: *"For volume and pan
the stage evaluates the source per sample, not per stride … Per-sample evaluation removes the last
approximation on the path that carries trance gates and auto-pan"*). The `±10.7 ms` edge slop the DJ
report computed applies to the **effect-param** path, which these do not touch.

| gesture | the exact calls | notes |
|---|---|---|
| **Tremolo** | `mod.addSource {kind:"lfo", params:{waveform:"sine", rateHz:5.5, bipolar:false}}` → `mod.addRoute {target:{kind:"volume"}, depth:-0.125}` | ⛔ **`bipolar:false` and a NEGATIVE depth are MANDATORY, not stylistic.** `Track.volumeRange` is `0...2`, a ceiling of **+6.02 dB**, so a bipolar source at a unity base clips its upper half and the result is not a tremolo. The contract emits `modulationVolumeCeiling` when you get this wrong. At the frozen `volumeFullScaleDb = 48`, depth `0.125` is a ±6 dB tremolo. |
| **Auto-pan** | a **SECOND, separate** source — same `waveform`/`rateHz`, but `bipolar:true` — → `mod.addRoute {target:{kind:"pan"}, depth:0.7}` | ⛔ **Do NOT reuse the tremolo's source.** That one is `bipolar:false` by necessity (see the row above), and a unipolar source on `.pan` yields an offset in `0 … 0.7` — it sweeps centre-to-RIGHT and never crosses to the left. `.pan` has no ceiling problem (domain ±1.0 at full depth), so **bipolar is both correct and required here**. The two gestures genuinely need two sources. |
| **Free-Hz gater** | `lfo` with `waveform:"square"`, `pulseWidth:0.3`, `edgeMs:2` → `.volume`, `bipolar:false`, `depth:-0.6` | ⚠️ **Same cut convention as §3.3: the square's HIGH half is the CUT, so `pulseWidth` is the CLOSED fraction** — `0.3` means chopped 30 % of the cycle, sounding 70 %. For short stabs of sound in mostly-silence, ask for `0.7`. `edgeMs` is a **closed-form raised-cosine** edge, not a filter — deterministic and seek-exact. Not tempo-synced ⇒ **not m39-d gated.** |

⚠️ **The floor, stated so nobody is surprised by it.** Full depth on `.volume` is `±48 dB`, so
`depth: -1` on a unipolar source reaches **−48 dB, not silence**. For most material that reads as
silence; for a bass-heavy loop under a loud mix it may not. **If a harder cut is wanted, that is an
argument with `ModulationDepth.volumeFullScaleDb`**, which the modulation design deliberately named
rather than buried *so it can be argued with*. Do not add a second attenuation mechanism to win the
argument.

### 3.3 Possible when m39-e + m39-c + m39-d land — the tempo-synced trance gate

```
mod.addSource { trackId: "<pad>", kind: "stepSequencer",
                params: { steps: [0,1,0,1, 0,1,0,1, 0,1,0,1, 0,0,1,1],
                          stepDivision: "1/16", edgeMs: 3 } }
mod.addRoute  { trackId: "<pad>", sourceId: "<id>",
                target: { kind: "volume" }, depth: -1.0 }
```

⛔ **POLARITY — read this before writing any `steps` array. It inverts the obvious reading, and I
had it backwards in the first draft of this document.**

Run the frozen depth law (modulation design §7.3) on the `.volume` domain, which is
`gain = base · 10^(sum·48/20)` with `sum = depth · s`:

| step value `s` | `sum` at `depth: -1.0` | gain | reads as |
|---|---|---|---|
| `1` | `-1` | `base · 10^(-48/20)` | **−48 dB — CLOSED** |
| `0` | `0` | `base` | **the knob value — OPEN** |
| `0.5` | `-0.5` | `base · 10^(-24/20)` | a 24 dB dip |

⭐ **So on `.volume`, the source's HIGH value is the CUT. `steps` entries are CUT AMOUNTS: `0` = open,
`1` = closed.** The pattern in the call above therefore reads as **sixteenth-note pulses for three
beats, then a held-open eighth (steps 12–13) closing into a silent eighth (14–15) into the downbeat**.

Nothing here is stylistic. It falls out of the depth law being an **offset from base**, where "open"
IS the base and therefore zero offset — so **no choice of depth sign makes `1` read as "open at
unity"**, and the convention has to be *stated* rather than inferred. `stepSequencer` carries **no
`bipolar` param** (modulation design §7.2) and its entries range `-1 … 1`, so a step that should
**BOOST** is written as a **negative entry**; that is true at either depth sign.

⚠️ **This will bite every novice, and the frozen contract's own default is the first casualty.** Its
`steps` default is `[1, 0, 1, 0]`, annotated *"a trance gate is `[1,0,1,0,...]`"* (modulation design
§7.2 table). Under the negative depth that `.volume` gating **requires**, that default renders
**closed-open-closed-open** — the inverse of how its own comment reads.

⛔ **This is NOT a defect I am ruling on, and NOT an amendment to the frozen contract — it is outside
this document's authority.** It is handed to the **m39-e implementer** as a documentation-or-ergonomics
call in the modulation contract's own court: either `mod.describeKinds` states the cut convention in
prose, or the source surface grows an `invert` flag. **Do not solve it inside an effect**, and do not
let an effect kind adopt the opposite convention to compensate.

⛔ **Both gates apply and neither is waivable.** `stepDivision` is tempo-synced ⇒ it needs **m39-c**
(the generalised resolver; the contract has it refuse with `modulationTempoSyncUnavailable` until then)
and it is a tempo-synced effect ⇒ **m39-d** (§8).

#### ⭐ And the classic sound is reachable, because sends are post-fader

The trance-gate idiom is *gated pad, reverb smoothing the gaps* — the reverb must be **after** the
gate. A fader-based gate gates last on its own strip, so an insert reverb would be **chopped** rather
than smoothing. But:

> `Sources/DAWCore/Model.swift:1467` — *"One post-fader send from a source track into a bus (M4 i)."*

**A post-fader send carries ALREADY-GATED audio into an UNGATED reverb bus, whose own fader no route
addresses.** The tail therefore rings through the gaps. That is exactly the classic sound, with zero
new DSP, and it is only true because the send is post-fader.

⛔ **THIS IS A DERIVATION FROM TWO VERIFIED FACTS, NOT A RENDER. I have not heard it.** Treat it as the
hypothesis it is, and prove it before it reaches a doc as fact. **The prescribed experiment, with its
positive control:**

1. Pad on track A, `stepSequencer → .volume` at `depth −1.0`. Reverb on bus B, long tail
   (`decaySeconds ≥ 3`), `mix 1.0`. Post-fader send A→B at a level that puts the bus within ~6 dB of
   the dry (per the §3.1 audibility warning — a quiet bus hides the result).
2. **Render the BUS STEM in isolation**, not the mix. The §3.1 measurement is the precedent: the same
   effect was 2.7 LU on the isolated stem and invisible in the mix.
3. Measure **momentary-loudness variance of the bus stem** across the gate period. The claim is that
   the bus stem's variance is **materially LOWER** than the track stem's — the tail filling the gaps
   is exactly what low variance means.
4. ⭐ **Positive control, and it is the part that makes the result mean anything: render variant (4)
   with the route `enabled:false`.** "The tail filled the gaps" and "I measured nothing" look identical
   in a loudness trace. The control must show the track stem's variance **collapse** when the route is
   disabled; if it does not, the instrument is broken and the main result is worthless.

**Deliverable (`m39-l`, weight S, gated on m39-c + m39-d):** the render above, then a preset, a skill
section, and the §9.1 demo set.

---

## 4. The three shared primitives — which are extracted, and how wide

⚠️ **The one-home law in this tree cuts both ways.** Seven verbatim copies once existed precisely
because there was nothing to call — *and* the stated corollary is that **a shared home that cannot
express real variation gets bypassed, and that is how the copies happen.** So each home below is
widened deliberately, with the safe default named and argued, and one of the three is deliberately
**not** created yet.

### 4.1 `InterpolatedDelayLine` — EXTRACTED. The only extraction in this milestone.

**Home:** `Sources/DAWEngine/Effects/Primitives/InterpolatedDelayLine.swift` (new directory).
**Lifted from:** `ChorusEffect.swift` — the flat two-channel block at `:44`/`:110`, the capacity
reasoning at `:104`, the write-head-crossing guarantee stated at `:12`, and the tap at `:131-143`.

**Why this one and not the others:** three separately-requested features need exactly it — FDN tail
modulation (anti-metallic), tape wow/flutter, and BBD pitch wobble — plus the flanger. **Four callers
before the first line is written** is what makes a home a home. And the subtle correctness condition
(*the interpolated read never crosses the write head*) is already reasoned about and paid for here;
a fresh implementation is most likely to get exactly that wrong.

#### How wide — and the ruling that keeps it from being bypassed

⛔ **The home is a DELAY LINE, not a MODULATED delay line.** Depth, rate, LFO shape and phase stay in
the caller. This is the deliberate widening decision and it is the whole answer to "a reverb tail
modulator and a tape wow need different depth/rate ranges": **they do — so the home does not have a
depth or a rate.** A home that owned modulation would have to own a range, every caller would need a
different one, and the first caller that did not fit would copy the file. Keeping modulation out means
there is nothing to disagree about.

What the home DOES express:

| axis | range the home must cover | **safe default**, and why |
|---|---|---|
| capacity | declared in **seconds** at `prepare()`: chorus 0.025 · flanger 0.020 · FDN tail-mod ~0.100 · tape delay 4.0 | **no default — the caller MUST declare it.** A defaulted capacity is how a tape delay silently gets a chorus's 25 ms line and truncates. This is the one parameter with no safe default, and the initialiser makes it non-optional for that reason. |
| interpolation | `linear` · `cubicHermite` | **`linear`.** It is what ships today, it is what the byte-identical chorus gate pins, and it is correct for every modulation depth in the musical band. `cubicHermite` exists for the tape delay, where a slow deep wow sweeps the fractional tap continuously and linear interpolation's frequency-dependent loss becomes a dull top end. **An implementer must not switch an existing caller to `cubicHermite` to "improve" it** — that reddens a byte-identical gate for a non-bug. |
| taps per read | N independent fractional reads against one write head | **2** (the chorus's voice count) is not a default, it is just the first caller's number. The API takes the delay per call: `tap(channel:delaySamples:)`. No tap-count state. |
| channels | 1 or 2, one flat block, per-channel base offset | **2.** The graph format is stereo deinterleaved throughout. |
| minimum delay | `minDelaySamples`, asserted at `prepare()` against the declared capacity | ⚠️ **INTERPOLATION-DEPENDENT: 1 sample for `.linear`, 2 for `.cubicHermite`** — see the addendum directly below, which corrects the flat "1 sample" this row carried until 2026-09-19. The write-head-crossing guarantee is expressed as an invariant the caller declares and the home checks **once, in `prepare()` on the main actor** — never on the render thread. A caller whose minimum can reach 0 (through-zero flanging) is refused at prepare, loudly, rather than reading its own write head. |

⚠️⚠️ **ADDENDUM 2026-09-19, WRITTEN AT EXTRACTION TIME — THE MINIMUM-DELAY FLOOR IS
INTERPOLATION-DEPENDENT, AND THE ROW ABOVE STATES IT WRONGLY.** The table says "**1 sample**"
flatly. That is correct for `.linear` and **wrong for `.cubicHermite`, which requires 2**: Hermite's
stencil reads `whole − 1`, i.e. one sample *newer* than the tap, so at a 1-sample minimum it reads
the write head — the exact condition this row exists to prevent.

⛔ **The concrete prediction: the tape-delay author reads this row, declares `minDelaySamples: 1`
alongside `.cubicHermite` (which §4.1 recommends to them by name, for the wow), and is refused at
`prepare()`.** The refusal names both numbers, so it is survivable — but a contract that predictably
refuses the caller it was written for is a contract defect, not a caller error. `.cubicHermite`'s
floor is **2**.

✅ **PREDICTION TESTED AND CONFIRMED, 2026-09-19 (m39-n).** The tape-delay author read this row,
declared `minDelaySamples: 1` with `.cubicHermite` **deliberately, as the experiment**, and was
refused at `prepare()` exactly as written:

```
PrepareRefusal.minimumDelayBelowStencil(minDelaySamples: 1.0, required: 2.0)
```

The refusal names **both** numbers — what was asked for and what is required — so a caller who reads
it can act on it. That is the standard a refusal has to meet. ⭐ **A design note that predicts a
specific future failure, and is then falsified-or-confirmed by the caller it predicted, is worth
more than one that merely describes the contract.** The shipped floor is derived rather than
literal — `TapeDelayParams.minimumDelaySamples(sampleRate:)` computes it from
`timeRange.lowerBound − wowDepthRange.upperBound − flutterDepthRange.upperBound` = 11.0 ms — so the
refusal is now structurally unreachable on valid params, and the inequality itself is pinned as a
test rather than left as a comment.

#### The arithmetic is frozen, because a gate depends on it

The extracted tap MUST perform, in this order and these types:

```
whole    : Int    = Int(delay)                    // delay is Double
fraction : Float  = Float(delay - Double(whole))
i0 = write - whole ; if i0 < 0 { i0 += capacity }
i1 = i0 - 1        ; if i1 < 0 { i1 += capacity }
return s0 + (s1 - s0) * fraction                  // Float arithmetic
```

⛔ **Not "an equivalent formulation".** Float addition is not associative and the migration gate below
is byte-identical. Rewriting this as `s0 * (1 - f) + s1 * f` is algebraically identical and
**numerically different**, and it will redden the gate for a non-bug — which is worse than a bug,
because someone will then weaken the gate.

#### ⛔ The home carries NO denormal flushing, and a feedback caller MUST add its own

⚠️ **Verified by me, 2026-09-19, and it is a trap the extraction creates rather than inherits.**
`ChorusEffect.swift:20-22` states outright: *"The chorus path is feedback-free (taps only), so it can
neither generate denormals nor blow up on finite input."* So the code being lifted has **never needed**
denormal handling and contains none.

**But three of its four new callers are feedback structures** — the flanger (§6.3), the tape delay, and
the FDN's recirculating lines — and a decaying feedback path is exactly where denormals appear.
`DelayEffect` already solves this and the solution is two lines: its header (`:21`) records *"Feedback
filter state is denormal-flushed per sample"*, implemented at `:217-218` as
`if abs(lpL) < 1e-20 { lpL = 0 }`. (Positive control for that grep: **9 of the files in
`Sources/DAWEngine/Effects/` mention denormals**, so the pattern is house-wide and the search works.)

**Frozen: the flush belongs to the CALLER, not to `InterpolatedDelayLine`.** A line that flushed its own
storage would impose a per-sample branch on the chorus, which provably does not need one, and would put
a threshold constant in a home that has no opinion about signal level. **Each feedback caller flushes
its own feedback state, matching `DelayEffect`'s existing approach rather than inventing a second.**

#### Sequence — and it is not optional

1. **Extract** the home with no caller. Unit-test it directly: a known impulse at a known fractional
   delay, a wrap across the capacity boundary, and a prepare-time refusal when `minDelaySamples` is 0.
2. **Migrate `ChorusEffect` onto it**, changing nothing else. ⭐ **Gate: a byte-identical render of a
   chorus project before and after.** Positive-control the gate by perturbing `depthMs` by one
   ULP-scale amount in a throwaway run and watching the comparison redden — a byte-comparison that has
   never failed is indistinguishable from one that cannot.
3. **Only then** build `.flanger` on the proven home (§6.3). The flanger is chosen as the second
   caller precisely because it is the cheapest one: if the home is wrong, it is cheap to find out.

⚠️ **Do not migrate `ChorusEffect` and build the flanger in one change.** If the byte-identical gate
reddens you will not know which half did it.

### 4.2 `Oversampler` — API DECLARED HERE, BUILT WITH ITS FIRST CALLER, EXTRACTED AT ITS SECOND

**This is the deliberate non-extraction**, and it is the one-home law applied honestly in the other
direction: **today there are zero callers.** The two candidates — `.clipper` and Saturator v2 — are
ranked 10 and 11 (§2.1), below everything in this milestone's build tier. A home built now would be
built against one imagined caller, which is precisely the too-narrow home the law warns about.

**But "build it when needed" is how seven copies happen.** So the resolution is a declared API that
the first caller must build to, in this document, now:

```swift
// Sources/DAWEngine/Effects/Primitives/Oversampler.swift — WHEN m39-s (clipper) is built
/// Polyphase FIR up/down sampler. Lines and scratch allocated in `prepare()`;
/// `up`/`down` are render-thread: no allocation, no locks, no ObjC.
final class Oversampler {
    init(factor: Int, maxFramesPerQuantum: Int, channelCount: Int)   // factor: 2 or 4
    var latencySamples: Int { get }        // feeds EffectRendering.latencySamples — PDC is measured
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int)
    func up(_ input: UnsafeMutableAudioBufferListPointer, frameCount: Int) -> UnsafeMutablePointer<Float>
    func down(into output: UnsafeMutableAudioBufferListPointer, frameCount: Int)
    func reset()
}
```

**Frozen rules for whoever builds it:**
- **`factor` is a constructor argument, not a constant.** The dynamics report wants 4x for hard
  clipping and 2x is enough for soft saturation; a home that hardcodes one gets copied by the other.
- **`latencySamples` is non-zero and MUST reach `EffectRendering.latencySamples`.** PDC for hosted AU
  inserts is measured sample-exact (m25-n, 2026-08-23, 0 samples residual) — a built-in effect that
  silently adds FIR latency would be the first thing in the tree to break that, and it would break it
  quietly. **The PDC test is part of the clipper's acceptance, not a follow-up.**
- **Extraction trigger, frozen: the SECOND caller.** When Saturator v2 lands, the clipper's oversampler
  moves to the shared home in the same change that adds the second caller — not before, not later.
  Filed as `m39-s` (clipper, builds it) and `m39-t` (Saturator v2, extracts it).

### 4.3 The capture ring buffer — DEFERRED, with its two blockers named so the spike does not rediscover them

Beat repeat, stutter/roll, backspin, tape stop and granular freeze all need to **re-emit a
musical-length window of audio that already flowed past**, on a read head decoupled from the write
head. ⭐ Verified: **nothing in `Sources/DAWEngine/Effects/` is that shape.** Every existing effect is
either stateless-per-sample or a short fixed-capacity line (delay ≤ 2 s, chorus ≤ 25 ms). This is
genuinely new infrastructure.

It is deferred (§10.1). What is **frozen here** is the shape of its two blockers, so the spike starts
from them instead of finding them:

**Blocker 1 — capacity is a preallocation decision, and it is bigger than it looks.** Two bars at
60 BPM is 8 s; stereo Float at 48 kHz is `8 × 48000 × 2 × 4 = 3.07 MB` **per strip that has one**.
Allocated in `prepare()`, never on the render thread, never resized. The spike must rule on whether
capacity is per-strip-fixed (simple, wasteful) or declared per effect instance (flexible, and then a
capacity change is a `prepare()` — i.e. a chain republish, which is a main-actor operation with its
own crossfade semantics). **Do not discover this at implementation time.**

**Blocker 2 — the effect cannot see the transport, and that is D8.**

#### ⭐ D8 FROZEN — the position-delivery API, decided now, built never (in this milestone)

**The shape, and it is the `storeAutomatedParam` pattern verbatim:**

```swift
// Sources/DAWEngine/Effects/EffectRendering.swift — additive
/// RENDER-THREAD: the schedule-relative sample position of this quantum's
/// first frame, plus the tempo in force. Called immediately before the chain
/// walk, on the same render thread, from the seam that already holds the
/// AudioTimeStamp. Contract: no allocation, no locks, no ObjC.
func storeRenderPosition(_ samplePosition: Int64, samplesPerBeat: Double)

extension EffectRendering {
    /// Default: inert. All 11 existing kinds land here and need ZERO edits.
    func storeRenderPosition(_ samplePosition: Int64, samplesPerBeat: Double) {}
}
```

**Call site:** the render-block closure in `ChainHostAU` already holds `timestamp` and already calls
`automation.storeEffectParams(chain:frameCount:timestamp:)` immediately before the chain walk. The new
call goes beside it and reuses the identical conversion.

⛔ **THE REAL COST IS NOT THE METHOD — IT IS THE ANCHOR, and this is the part a spike would miss.**
`AutomationRenderer.quantumStart(of:timestamp:)` is **private** and switches on
`AutomationSchedule.Mode` (`.live(anchorHostTime:)` / `.offline` with a latched epoch,
`AutomationSchedule.swift:41-44`). **A strip with no published `AutomationSchedule` has no anchor and
therefore no position at all.** m39-e does not close this in general: it publishes a synthetic
one-point hold track for modulated-but-unautomated params, so a schedule exists **whenever modulation
exists** — but a strip carrying only a beat-repeat effect, with no lanes and no routes, would have
neither.

⭐⭐ **MEASURED AT REVIEW — and the cost is LOWER than the paragraph above implies, because
m39-e has ALREADY BUILT the anchor-only publish.** I had written the predicate up as unbuilt work;
checking it rather than asserting it changed the number.

⚠️ **State I saw:** `PlaybackGraph.swift` and `AutomationSchedule.swift` **mid-edit** by the
concurrently-running m39-e implementation. Cited by symbol, not line, per the brief.

`AutomationSchedule.build(...)` and `buildLoopUnrolled(...)` both already take a
**`requireAnchor: Bool = false`** parameter, and both already guard
`requireAnchor || !volume.isEmpty || !pan.isEmpty`. Its own doc comment states the purpose outright:

> *"MODULATION ROUTE has no points but still needs the schedule's ANCHOR — `quantumStart` is how the
> render side learns the transport position. An empty-point schedule is inert for automation by
> construction (every stage guards `count > 0`), so this cannot change any existing render."*

It is threaded through `PlaybackGraph.buildRollSchedule` and `publishMasterAutomation`, and the strip
publish path computes it as **`let requireAnchor = modulatesVolume || modulatesPan`**.

**So the general mechanism — publish a lane-less, point-less, render-inert schedule purely to carry an
anchor — exists, ships, and is already argued to be render-safe.** What is missing is only that its
predicate names *modulation* and not *effects*.

⭐ **Revised α cost, and this is the number for the spike:**
1. the protocol method + default-inert extension (free, zero edits to 11 conformers);
2. the call beside `storeEffectParams` in `ChainHostAU` (free, the timestamp is already in hand);
3. **widening ONE boolean** to `modulatesVolume || modulatesPan || chainNeedsRenderPosition`, where the
   third term is a main-actor walk of the strip's effect descriptors — the same walk
   `resolveEffectParamLanes` already performs.

⚠️ **Two things the spike must still verify rather than inherit from me.** (a) `requireAnchor`'s
render-inertness argument is stated for *automation* stages; a position consumer is a NEW reader of
that schedule and must confirm `quantumStart` is meaningful on a point-less schedule rather than
merely harmless. (b) `quantumStart(of:timestamp:)` is **private** to `AutomationRenderer`; exposing it
is a visibility change, small but not zero. **D8 stays DEFERRED — this lowers its price, it does not
schedule it.**

**And the degrade behaviour is frozen too:** an effect that receives no position **must not improvise
one from a frame counter.** A counter is history-dependent, breaks seek-exactness and makes live and
offline disagree — the exact property m39-e §3.2 exists to protect. An effect with no position holds
neutral (dry), the same way a stopped transport lets the knobs rule.

---

## 5. The reverb ruling

### 5.1 Adopted: an 8-line FDN as a new additive kind

**ADOPTED as recommended by `docs/research/2026-09-19-reverb-delay-space.md` §9**, with two cuts and
one sizing decision:

- **8 lines, not 8–16.** Ship 8. The report offers a range; a range is not a decision and a line count
  is a preallocation. 8 Householder-mixed lines with per-line two-band absorption is comfortably dense
  for a hall, is `O(N)` per sample, and 16 can be **appended later as a `density` param** without
  moving a single automation slot. Shipping 16 first and discovering it is CPU-heavy is the expensive
  direction; shipping 8 and appending is the cheap one.
- **`duckAmount` / `duckThresholdDb` / `duckReleaseMs` — CUT (D9).** Measured-working already; see §3.1.
- **`shimmerMix` / `shimmerIntervalSemitones` — CUT (D10).** A pitch shifter inside a feedback loop,
  and no pitch shifter exists.

**Why FDN and not the alternatives** — the report's argument holds and I am not re-deriving it, but the
two that matter here, restated in this tree's terms:

- **vs. keeping Freeverb and adding params:** structurally impossible. ⚠️ **Provenance: verified by
  the ORCHESTRATOR against source (inventory §7), not by me** — `ReverbEffect.swift` is deliberately
  absent from §0's list of what I read first-hand. The finding is cited as fact because §7–§11 were
  checked line by line; the citations below are theirs. `ReverbEffect.swift:29-30` — comb lengths are compile-time constants
  (`1116, 1188, 1277, …`). `:135`/`:151` multiply them by a `scale` factor, and `:127` shows that
  `scale = sampleRate / 44_100.0`, i.e. **sample-rate normalisation, computed once in `prepare()`**. No
  parameter reaches those lengths. ⭐ The `scale` factor is why this needed reading rather than
  grepping: a reader who greps `roomSize` concludes "fixed tunings"; a reader who notices `scale` could
  conclude the opposite. Both greps are correct and one conclusion is wrong.
- **vs. hosting `AVAudioUnitReverb`:** its Swift-level surface is presets plus one mix knob — **strictly
  worse than what we ship today**, and it would route through the AU-parameter bridge instead of the
  atomic-POD-publish + `AutomationParamOverlay` path every built-in already uses. It adds integration
  cost rather than saving it. (⚠️ This is the one place where "Apple's 23 built-in AU effects work,
  measured 2026-08-13" does **not** argue for hosting: working is not the same as controllable.)

### 5.2 What happens to `.reverb` — LEFT ALONE, DOCUMENTED HONESTLY, NOT DEPRECATED

⛔ **`roomSize` cannot be renamed.** Wire and parameter names are additive-only, and `.reverb`'s
automation slots are positional — `roomSize` is frozen at **slot 0 forever**. Verified: `:213`,
`combFeedback = Float(0.7 + 0.28 * p.roomSize)`, is the *only* place it reaches the DSP, and it scales
comb **feedback**. It is a mislabeled RT60/decay control.

**The ruling, of the three offered:**

| option | verdict |
|---|---|
| leave it alone | ✅ **taken, for behaviour** — not one byte of `ReverbEffect` changes |
| document it honestly | ✅ **taken, for metadata** — see below |
| deprecate it in prose | ⛔ **rejected.** Deprecation creates a second-class effect agents route around while real projects still render through it, and it invites someone to "finish the job" by changing behaviour. Freeverb's small, bright, dense room is a genuinely good sound that the FDN's hall will not replicate. |

**The honest documentation is additive metadata, and it moves nothing.** `EffectParamSpec` already
carries an optional free-text `note` surfaced verbatim by `fx.describe` (the EQ v2 precedent). Adding
a `note` to an existing spec entry changes neither the name, the range, the default, nor the position —
**so no automation slot moves and no saved project changes.** Frozen text obligations for `m39-m`:

- on `reverb.roomSize`: it controls **how long the tail rings (decay), not how big the space is**;
  the room's dimensions are fixed; for a real size control use `hallReverb.sizeMeters`.
- on the `.reverb` kind description: a fixed-size, fixed-tuning bright room with no
  frequency-dependent decay and no tail modulation; `.hallReverb` is the one with size, two-band decay
  and an anti-metallic modulated tail.

⚠️ **This must land in BOTH `EffectParamSpec.specs(for: .reverb)` AND the MCP tool description**, or an
agent reading `fx_describe` and an agent reading the tool text disagree — this tree's named
characteristic failure mode, *the record says X, the source says Y, and nothing compares them*.

### 5.3 The Dattorro plate — a MODE, conditionally, and the condition is a measurement

**Frozen decision rule (D4), not a decision:**

> A Dattorro/Griesinger plate ships as `hallReverb.topology = plate` **if and only if** its total
> delay-line requirement at the **lowest supported sample rate** fits inside the allocation
> `prepare()` already makes for the FDN at `sizeMetersRange.upperBound`. Otherwise it is its own kind.

**Why a rule and not a decision:** a mode whose state does not fit forces one of two unacceptable
outcomes — a reallocation on the render thread (forbidden outright), or a permanently oversized
allocation carried by every hall user to serve a plate they never load. Neither is decidable from
here. **The prior is favourable** — a plate tank is a constrained two-loop FDN whose lines total well
under a second, against an 8-line hall sized for 60 m — so `plate` is *likely* a mode. Likely is not
frozen.

**And when it ships, it ships as an APPENDED param.** `topology` goes on the end of the spec array, so
the v1 params keep their slots. ⛔ **Do NOT reserve a `topology` slot in v1.** Appending is always
safe; reserving puts a parameter in `fx.describe` that does nothing, which is a lie told to every agent
that reads the table, to buy an ordering that was never at risk.

### 5.4 Naming — frozen

| thing | frozen value | why |
|---|---|---|
| enum case | **`hallReverb`** | Matches `HallReverbParams` in the research report, so an implementer cross-referencing it finds the same word. `reverb2` is unrenameable and opaque to a novice; `fdnReverb` names an algorithm the user does not have. |
| v1 display label | **"Hall Reverb"** | |
| label once `topology` ships | **"Hall & Plate"** | The display label is a UI mapping, not a wire name, so it is free to change. ⚠️ **The enum case is NOT** — `hallReverb` is permanent from the first commit. |
| params struct | **`HallReverbParams`** | |

### 5.5 Tail modulation — the anti-metallic fix, and its one honest caveat

Each of the 8 lines gets a slow, small, **independent-phase** length modulation read through
`InterpolatedDelayLine` (§4.1). This is the textbook fix for the metallic ringing that fixed-length
recirculating networks produce, and the primitive already exists.

⚠️ **Frozen depth ceiling, and the reason:** `modDepthMs` tops out at **5 ms** and defaults to
**0.15 ms**. Tail modulation pitch-modulates the recirculating signal; past a few milliseconds on a
long tail it stops sounding like *air* and starts sounding like *chorus*, which is a different effect
that we also ship. The ceiling is generous enough to reach that sound deliberately and low enough that
the default cannot stumble into it.

⚠️ **`sizeMeters` is `warned`, not `yes`, and the reason is physical, not numerical.** Lines are
MAX-sized at `prepare()` for `sizeMetersRange.upperBound`, so moving `size` is arithmetic on a read
offset, never an allocation. But moving the read offsets **while audio is in the tail sweeps every
recirculating delay**, which **pitch-shifts the existing tail like a varispeed**. It is smooth, not a
click — it is not the `delay.timeMs` integer-snap defect — but an agent automating `sizeMeters` gets a
Doppler glide it did not ask for. The `modulationTargetSteps` warning must say exactly that, in those
terms. ⭐ **It is also a good sound**, which is why this is `warned` and not `refused`: a slow size
ramp under a pad is a real production gesture.

---

# 6. FROZEN CONTRACT — parameter surfaces

**Everything from here to the end of §7 is normative.** Implementers follow it verbatim. A deviation
is made by amending this section in a commit that says so, not by code that quietly differs.

## 6.0 Rules every new effect kind inherits, restated so none is discovered late

1. **The param array is APPEND-ONLY FOREVER.** Position in `EffectParamSpec.specs(for:)` **is** the
   automation slot (`storeAutomatedParam(slot:value:)`). Inserting a param in the middle silently
   re-points every saved automation lane on that effect. Design the v1 order as if it were permanent,
   because it is. ⭐ **The corollary that saves work: never reserve a slot.** Appending is always safe,
   so a reserved-but-inert param buys an ordering that was never at risk and puts a lie in
   `fx.describe`.
2. **Every param declares `curve` explicitly.** `EffectParamSpec.init` has **no default** for it
   (`Effects.swift:942-944`, deliberately — *"a defaulted `.linear` is inference-by-omission"*).
   ⚠️ `.logarithmic` and `.decibel` **require `lo > 0`**; `ParamCurveConformanceTests`'
   `multiplicativeCurvesHaveAPositiveLowerBound` asserts it over every shipping table, and the runtime
   fallback to linear is **silent**. A range that touches 0 takes `.linear`, full stop.
3. **Every param declares a `Modulatable` verdict** (`yes` / `warned` / `refused`) per the modulation
   design §6.1. ⛔ **Frozen invariant: modulation refuses a SUPERSET of what automation refuses.**
   Modulation never permits something automation forbids.
4. ⛔ **The §6.2 totals test MUST grow with each new kind.** The modulation contract pins
   **31 yes / 18 warned / 15 refused = 64 across 11 kinds** against `EffectParamSpec.specs(for:)`.
   Each new kind adds its own counts in the same change that adds the kind. A new param without a
   verdict must fail that test loudly — that is the whole point of it.
5. **The numeric surface is total.** Booleans and enums are expressed as numeric params (`0...1`
   binary with `>= 0.5` = on, per `gain.invertPolarity` and `limiter.truePeak`; or an index range that
   `.rounded()`s, per `eq.highPassSlopeDbPerOct`). The Swift struct may hold `Bool` or an enum; the
   **spec table never does**. All such params are `Modulatable: refused`, reason `discrete`.
6. ⭐ **NEW OBLIGATION, and it is what earns a `yes` verdict: a new creative effect SMOOTHS ITS OWN
   DERIVED STATE INTERNALLY.** Effect params arrive as **one scalar per quantum** and that is not
   changing — the `(start, end)` ramp interface was priced at 21 files and **declined** (modulation
   design §6.3). So an effect whose derived coefficients would step audibly is not permitted to shrug
   and take `warned`: it interpolates internally. **The frozen shape** (§6.1.3) is a per-sample linear
   interpolation of the derived control value across the quantum, with coefficients recomputed every
   **32 frames** — the same stride the modulation design froze, for the same reason.
   ⚠️ **This is why `eq` is `warned` and the new kinds are not.** `eq` predates the rule and fixing it
   is `m39-e-D3`; nothing new inherits its excuse.
7. **Bit-exact dry at zero.** Every kind with a `mix` must be **bit-exact dry at `mix == 0`** and must
   still advance its lines and oscillators so a later `mix` raise is phase-coherent (the `ChorusEffect`
   convention, `:14-15`). For kinds with no `mix` (`.djFilter`), the equivalent neutral position is
   named in that kind's section.
8. **Render-path contract, non-negotiable:** `process()` and `reset()` allocate nothing, take no locks,
   log nothing, touch no ObjC, hop no actors. All memory is allocated in `prepare()` on the main actor,
   sized for the **maximum** of every range so every parameter move is arithmetic and never an
   allocation. ⚠️ Render-path loops are `while`, **not** `for i in 0..<n` — measured at
   `EffectChainProcessor.swift:402-412`, a `Range` iteration raises ~2 malloc/free events *per
   iteration* at `-Onone`, and the allocation gates assert an **absolute** zero.
9. **`latencySamples` is real and must be reported.** PDC for inserts is measured sample-exact
   (m25-n). An effect that adds latency and reports 0 breaks a working, verified guarantee quietly.
   Every kind in §6 reports **0** except any that later adopts the `Oversampler`.
10. **Additive-optional on the descriptor.** Each kind adds `public var <kind>: <Kind>Params?` plus
    `public var resolved<Kind>: <Kind>Params { <kind> ?? <Kind>Params() }` to `EffectDescriptor`, and
    the new field is **omitted when nil** so pre-existing projects stay **byte-identical on disk**.
    Decoding routes through the clamping init with `decodeIfPresent ?? default` per field, so a partial
    object decodes (the `ChorusParams` pattern, `Effects.swift:756-762`).
11. **Every capability ships a control command, an MCP tool, and a test.** New kinds need **no new
    verb** — `fx.add` / `fx.setParam` / `fx.describe` are kind-generic and address params **by name**
    with clamp-and-warn semantics. ⭐ **That is the argument for having zero new verbs in this
    milestone**, and it is worth stating: the wire command count should move by **0** for §6.1–§6.4.
    **If a `doc-count-drift` run after these items reports a changed command count, something was added
    that this contract did not authorise.** That is a usable tripwire; use it.

---

## 6.1 `.djFilter` — RANK 1, BUILD FIRST

The single highest-identity item in the domain, named by the user ("DJs"), and **the only one with no
gate in front of it**.

### 6.1.1 The struct

```swift
/// Single-knob bipolar resonant filter — the club-mixer / DJ-mixer sweep.
/// `position` 0 is a bit-exact dry centre; negative sweeps a HIGH-pass upward
/// (bass disappears first), positive sweeps a LOW-pass downward (treble
/// disappears first). ONE knob, because that is the entire instrument.
///
/// NO `mix` PARAMETER, DELIBERATELY: summing a resonant filter with its own dry
/// signal is comb filtering, not a gentler filter. The dry/wet blend that does
/// exist is `deadZoneWidth`, which crossfades to dry only across the centre.
public struct DJFilterParams: Codable, Sendable, Equatable {
    /// -1 = full high-pass … 0 = bypass … +1 = full low-pass.
    public var position: Double
    /// 0 = Butterworth (Q 0.707) … 1 = Q 10, on the edge of self-oscillation.
    public var resonance: Double
    /// 12 or 24 dB/oct; other values snap to the nearer.
    public var slopeDbPerOct: Double
    /// Half-width of the centre region that crossfades to dry. 0 disables the
    /// crossfade entirely (the filter engages the instant `position` leaves 0).
    public var deadZoneWidth: Double
    /// How much `resonance` rises toward the sweep extremes — the "isolator"
    /// feel. 0 = constant resonance across the whole sweep (predictable).
    public var resonanceTrack: Double

    public static let positionRange: ClosedRange<Double> = -1...1
    public static let resonanceRange: ClosedRange<Double> = 0...1
    public static let slopeRange: ClosedRange<Double> = 12...24
    public static let deadZoneRange: ClosedRange<Double> = 0...0.2
    public static let resonanceTrackRange: ClosedRange<Double> = 0...1

    // MARK: The cutoff law — ONE HOME, in DAWCore, read by the DSP, the UI and
    // `fx.describe`'s note text. An agent that cannot compute this is guessing.

    /// Lowest cutoff either sweep reaches, Hz.
    public static let cutoffFloorHz = 20.0
    /// Highest cutoff either sweep reaches, Hz.
    public static let cutoffCeilingHz = 20_000.0

    /// The cutoff a given `position` selects, and `nil` at a bypassing centre.
    /// Log-symmetric about the centre: each sweep spans the full
    /// `log2(20000/20) = 9.97`-octave audible range, so equal knob travel is
    /// equal musical travel at both ends.
    ///   position < 0 : HIGH-pass,  f = 20 · (20000/20)^|position|
    ///   position > 0 : LOW-pass,   f = 20000 · (20/20000)^position
    public static func cutoffHz(atPosition position: Double) -> Double? { /* … */ }

    public init(position: Double = 0, resonance: Double = 0.25,
                slopeDbPerOct: Double = 24, deadZoneWidth: Double = 0.04,
                resonanceTrack: Double = 0) { /* each .clamped(to:) */ }
}
```

### 6.1.2 The spec table — order is FROZEN (position == automation slot)

| slot | name | range | default | unit | **curve** | **Modulatable** | why |
|---:|---|---|---:|---|---|---|---|
| 0 | `position` | -1 … 1 | 0 | linear | **`.linear`** | **yes** | ⚠️ `.linear` is **forced**, not chosen: the range crosses 0, so `.logarithmic` is invalid. The log-ness lives in `cutoffHz(atPosition:)`, which is exactly why that function is a declared home and not an implementation detail. ⭐ **Consequence for the depth law: full modulation depth on `position` is `±2.0`, i.e. the entire sweep in both directions.** A `depth: 0.25` LFO is a half-range wobble. Say this in the MCP text. |
| 1 | `resonance` | 0 … 1 | 0.25 | linear | `.linear` | **yes** | `Q = 0.707 + resonance · 9.293`. |
| 2 | `slopeDbPerOct` | 12 … 24 | 24 | dB/oct | `.linear` | **refused** (`discrete`) | Snaps to 12 or 24 — a topology switch, the `eq.highPassSlopeDbPerOct` precedent verbatim. |
| 3 | `deadZoneWidth` | 0 … 0.2 | 0.04 | linear | `.linear` | **yes** | Continuous and arithmetic. Modulating it is pointless but harmless, and `refused` would be a lie about why. |
| 4 | `resonanceTrack` | 0 … 1 | 0 | linear | `.linear` | **yes** | `Q_eff = Q · (1 + resonanceTrack · |position|²)`. Default 0 keeps the sweep predictable; the report's `curveCharacter: aggressive` enum is expressed as this continuous param instead, because a continuous param is modulatable and an enum is not. |

**Totals contributed: 4 yes, 0 warned, 1 refused.**

### 6.1.3 DSP — frozen shape

- **Topology: a 2-pole Simper TPT state-variable filter, cascaded twice for 24 dB/oct.** ⭐ Reuse the
  coefficient derivation already in `Sources/DAWEngine/Instruments/PolySynthInstrument.swift` (`:291`,
  *"2-pole SVF (Simper TPT form, shared coefficients)"*) — **and note that it is already benchmarked**:
  the architect measured the coefficient triple at **11.5–18.2 ns** at `swiftc -O`. At a 32-frame
  stride that is ~0.003 % of a core. This is not a budget item; do not re-measure it to find out.
  ⚠️ Lift the **math**, do not `import` the instrument. `DAWCore` stays engine-free and the instrument
  stays out of the effects path; a small duplicated derivation with a comment naming the sibling is
  correct here, and a third copy is when it gets a home.
- **The 24 dB/oct cascade is two identical 12 dB sections**, not a redesigned 4-pole. Resonance applies
  to the **second** section only, so `slopeDbPerOct` does not change the resonant peak's height — a
  user flipping 12↔24 hears steepness change, not loudness.
- ⛔ **Coefficient smoothing is MANDATORY (rule 6.0.6), and this is its frozen shape:**
  `position` arrives as one scalar per quantum. The effect keeps the **previous** quantum's derived
  cutoff, linearly interpolates toward the new one **per sample** across the quantum, and recomputes
  the SVF coefficient triple every **32 frames**.
  ⚠️ **This lags by at most one quantum (≤ 10.7 ms at 512 frames) and is therefore BLOCK-SIZE
  DEPENDENT.** That is **accepted and out of m39-d's scope**, and the reason is precise: m39-d gates
  **edge placement**, and a continuous filter sweep has no edges. 10.7 ms on a one-second sweep is 1 %
  of the gesture. ⛔ **This mechanism must NEVER be used to place an edge.**
  **Pinned by a TOLERANCE test, not a bit-exactness test** (§12).
- **Dead zone.** Wet gain `w` ramps `0 → 1` over `|position| ∈ [0, deadZoneWidth]` with a raised-cosine
  shape; output is `dry·(1−w) + wet·w`. At `position == 0` exactly, `w == 0` and **the filter is not run
  at all** — bit-exact dry by IEEE (the `mix == 0` convention, rule 6.0.7). The SVF integrators still
  advance so re-entering the sweep is continuous, never a click.
- **Output protection at high `resonance`.** A Q of 10 near self-oscillation can exceed the input by
  ~20 dB. **Frozen: apply `1 / sqrt(Q)` normalisation to the resonant section's output.** ⛔ Do **not**
  insert a limiter inside the effect — that makes resonance non-linear in a way an agent cannot predict
  and a user cannot undo.

### 6.1.4 Why this is not m39-d gated — stated once, so it is not re-litigated

No tempo sync. No edges. No `NoteDivision` anywhere in the surface. The DJ report reached the same
conclusion independently (§9.6a) and its reasoning is sound: the effect's quality depends on
**continuous** sweeping, and at 93.75 Hz even the fastest deliberate flick (~100 ms) gets ~9 update
points, which the internal per-sample interpolation above then makes continuous. **`.djFilter` ships
before m39-c and before m39-d.**

---

## 6.2 `.hallReverb` — RANK 3, the largest quality win

### 6.2.1 The struct

```swift
/// 8-line Feedback Delay Network with Householder mixing, per-line two-band
/// absorption and small independent length modulation. Ships ALONGSIDE the
/// Freeverb `.reverb`, which is untouched.
///
/// The difference that justifies a second kind, in one line: this one has a
/// SIZE. `.reverb`'s `roomSize` scales comb FEEDBACK — its comb lengths are
/// compile-time constants (verified, `ReverbEffect.swift:29-30`, :213), so its
/// room has exactly one shape forever.
public struct HallReverbParams: Codable, Sendable, Equatable {
    public var mix: Double
    public var decaySeconds: Double          // RT60 at the 1 kHz reference band
    public var sizeMeters: Double            // line-length scale; an actual size
    public var preDelayMs: Double
    public var width: Double
    public var diffusion: Double
    public var earlyLateBalance: Double      // -1 close/early … +1 far/diffuse
    public var lowDecayMultiplier: Double    // RT60 x, below lowCrossoverHz
    public var highDecayMultiplier: Double   // RT60 x, above highCrossoverHz
    public var lowCrossoverHz: Double
    public var highCrossoverHz: Double
    public var modRateHz: Double             // anti-metallic tail modulation
    public var modDepthMs: Double
    public var freeze: Double                // >= 0.5 = infinite hold

    public static let mixRange: ClosedRange<Double> = 0...1
    public static let decayRange: ClosedRange<Double> = 0.1...20
    public static let sizeRange: ClosedRange<Double> = 1...60
    public static let preDelayRange: ClosedRange<Double> = 0...250
    public static let widthRange: ClosedRange<Double> = 0...1.2
    public static let diffusionRange: ClosedRange<Double> = 0...1
    public static let earlyLateRange: ClosedRange<Double> = -1...1
    public static let lowDecayMultiplierRange: ClosedRange<Double> = 0.25...4
    public static let highDecayMultiplierRange: ClosedRange<Double> = 0.1...1
    public static let lowCrossoverRange: ClosedRange<Double> = 50...1_000
    public static let highCrossoverRange: ClosedRange<Double> = 1_000...16_000
    public static let modRateRange: ClosedRange<Double> = 0.05...5
    public static let modDepthRange: ClosedRange<Double> = 0...5
    // init: every field .clamped(to:) — the GainParams/ChorusParams pattern.
}
```

### 6.2.2 The spec table — order is FROZEN

| slot | name | range | default | unit | **curve** | **Modulatable** | why |
|---:|---|---|---:|---|---|---|---|
| 0 | `mix` | 0 … 1 | 0.3 | linear | `.linear` | **yes** | bit-exact dry at 0 (rule 6.0.7) |
| 1 | `decaySeconds` | 0.1 … 20 | 1.8 | s | **`.logarithmic`** | **yes** | 7.6 octaves of travel; linear would bury everything under 4 s in the last fifth of the knob |
| 2 | `sizeMeters` | 1 … 60 | 12 | m | **`.logarithmic`** | ⚠️ **warned** | lines are MAX-sized at `prepare()` so this is arithmetic, never an allocation — **but moving it while audio is in the tail pitch-shifts that tail like a varispeed** (§5.5). Smooth, not a click; the warning must say *Doppler glide*, not *steps* |
| 3 | `preDelayMs` | 0 … 250 | 20 | ms | `.linear` | **yes** | ⭐ read through `InterpolatedDelayLine`, so unlike `reverb.preDelayMs` (`warned`, integer read offset) this one moves smoothly. `.linear` is **forced**: `lo == 0` |
| 4 | `width` | 0 … 1.2 | 1.0 | linear | `.linear` | **yes** | M/S on the wet only. Ceiling 1.2, not higher, for mono compatibility |
| 5 | `diffusion` | 0 … 1 | 0.7 | linear | `.linear` | **yes** | input allpass density |
| 6 | `earlyLateBalance` | -1 … 1 | 0 | linear | `.linear` | **yes** | `.linear` **forced** — crosses 0 |
| 7 | `lowDecayMultiplier` | 0.25 … 4 | 1.0 | x | **`.logarithmic`** | **yes** | a multiplier's neutral is 1, and 0.25/4 are symmetric in octaves, not in units — linear travel would put neutral at 20 % of the knob |
| 8 | `highDecayMultiplier` | 0.1 … 1 | 0.5 | x | **`.logarithmic`** | **yes** | default < 1 models air absorption; this is what stops the tail sounding like a metal tank |
| 9 | `lowCrossoverHz` | 50 … 1 000 | 200 | Hz | **`.logarithmic`** | **yes** | shelf coefficients smoothed internally (rule 6.0.6) |
| 10 | `highCrossoverHz` | 1 000 … 16 000 | 6 000 | Hz | **`.logarithmic`** | **yes** | same |
| 11 | `modRateHz` | 0.05 … 5 | 0.3 | Hz | **`.logarithmic`** | **yes** | |
| 12 | `modDepthMs` | 0 … 5 | 0.15 | ms | `.linear` | **yes** | `.linear` **forced**: `lo == 0`. Ceiling 5 ms is deliberate (§5.5) |
| 13 | `freeze` | 0 … 1 | 0 | linear | `.linear` | **refused** (`discrete`) | `>= 0.5` = on. Drive it with an `automation.addLane` `hold` lane (D7) |

**Totals contributed: 12 yes, 1 warned, 1 refused.**

⛔ **CUT FROM v1, and named so nobody adds them quietly:** `preDelaySync` / `preDelayDivision`
(**tempo-synced ⇒ would drag the whole kind behind m39-c and m39-d**, which is a bad trade for one
convenience param — append them after §8 clears); `duckAmount` / `duckThresholdDb` / `duckReleaseMs`
(D9, measured-working already); `shimmerMix` / `shimmerIntervalSemitones` (D10, needs a pitch shifter);
`topology` (D4, appended when the plate ships); `density` (8 vs 16 lines, appended if 8 proves thin).

### 6.2.3 DSP — frozen shape

- **8 lines, Householder mixing.** `O(N)` per sample: a Householder reflection is a dot product plus a
  scaled subtraction, not an N×N multiply. Prime-ish line lengths scaled by `sizeMeters` so modes do
  not coincide.
- **Per-line absorption: one low shelf + one high shelf**, derived from `decaySeconds`,
  `lowDecayMultiplier`, `highDecayMultiplier` and the two crossovers. Per-line gain is
  `10^(-3 · lineLengthSeconds / rt60Band)` — the standard RT60 relation, so `decaySeconds` means
  decibels of decay, not an arbitrary feedback number.
- **Tail modulation through `InterpolatedDelayLine`** (§4.1), one independent LFO phase per line.
  **Declared capacity: 0.100 s** (max `modDepthMs` plus interpolation margin), separate from the line
  storage itself.
- **Pre-delay through the same primitive**, capacity `preDelayRange.upperBound` + margin = 0.260 s.
- ⛔ **Denormals: read `DelayEffect`'s existing denormal-safe feedback handling and MATCH it.** A long
  RT60 decays into denormal territory and denormal arithmetic can cost 100x on some paths. Do **not**
  invent a second approach; there is already one in this directory.
- **`freeze` transition:** the input mute crossfades over ~10 ms and the absorption shelves are
  bypassed (unity feedback). A hard switch on either is a click. The crossfade is a fixed-length ramp
  in preallocated state — no allocation, no branch on parameter identity in the inner loop.
- **Allocation:** every line is sized at `prepare()` for `sizeRange.upperBound` at the prepared sample
  rate. A `sizeMeters` change is a read-offset change. **Nothing resizes, ever.**
- **`latencySamples` = 0.** The FDN is not a lookahead structure; pre-delay is signal delay the user
  asked for, not algorithmic latency, and reporting it as latency would have PDC compensate away the
  parameter.

---

## 6.3 `.flanger` — RANK 2, and the proof that §4.1's home is real

Built **after** `ChorusEffect` is migrated onto `InterpolatedDelayLine` and its byte-identical gate is
green — never in the same change (§4.1).

### 6.3.1 The struct and spec table

```swift
/// Feedback flanger: one interpolated delay tap per channel swept by an LFO,
/// with BIPOLAR feedback. Negative feedback is the hollow/metallic side and is
/// half the reason to have a flanger at all, which is why `feedbackRange`
/// crosses zero.
public struct FlangerParams: Codable, Sendable, Equatable {
    public var rateHz: Double
    public var depthMs: Double          // sweep RANGE, added upward from delayMs
    public var delayMs: Double          // the "manual" knob: the sweep's FLOOR
    public var feedback: Double         // -0.95 … 0.95
    public var mix: Double
    public var stereoPhaseDeg: Double
    // ranges + clamping init, ChorusParams pattern
}
```

| slot | name | range | default | unit | **curve** | **Modulatable** | why |
|---:|---|---|---:|---|---|---|---|
| 0 | `rateHz` | 0.02 … 10 | 0.3 | Hz | **`.logarithmic`** | **yes** | 9 octaves; linear travel makes everything under 1 Hz unreachable |
| 1 | `depthMs` | 0.1 … 10 | 3 | ms | **`.logarithmic`** | **yes** | math on a MAX-sized line |
| 2 | `delayMs` | 0.1 … 10 | 1.0 | ms | **`.logarithmic`** | **yes** | the sweep floor; guarantees the read never reaches the write head |
| 3 | `feedback` | -0.95 … 0.95 | 0.5 | linear | `.linear` | **yes** | `.linear` **forced** — crosses 0, and crossing 0 is the point |
| 4 | `mix` | 0 … 1 | 0.5 | linear | `.linear` | **yes** | bit-exact dry at 0 |
| 5 | `stereoPhaseDeg` | 0 … 180 | 90 | deg | `.linear` | **yes** | R LFO phase offset from L |

**Totals contributed: 6 yes, 0 warned, 0 refused.**

### 6.3.2 The one design decision that prevents the classic bug

⛔ **The LFO modulates UPWARD ONLY: `delay = delayMs + depthMs · (0.5 + 0.5·sin(φ))`.**

A bipolar sweep (`delayMs + depthMs·sin(φ)`) goes **negative** whenever `depthMs > delayMs` — and both
ranges are `0.1 … 10`, so the default surface permits it trivially. The fixes people reach for are a
clamp (which flattens the sweep bottom and sounds broken) or a runtime guard (which is a branch in the
inner loop that hides the mistake). **Modulating upward from a floor removes the failure mode
entirely**: `delay ∈ [delayMs, delayMs + depthMs]`, always `≥ 0.1 ms`, always positive, no clamp, no
branch. It is also how a hardware flanger's manual knob actually behaves.

**Declared line capacity: 0.020 s** (`delayMs.upper + depthMs.upper` = 20 ms, plus the home's margin).
`minDelaySamples` is declared from `delayMs.lowerBound` and checked at `prepare()`.

⚠️ **Through-zero flanging is NOT this effect** and must not be added to it. TZF requires a second
delayed dry path so the two can cross, plus a `minDelaySamples` of 0 which §4.1 refuses by design. It
is a separate kind if anyone ever wants it.

---

## 6.4 `.ringMod` — RANK 4, and the user said "frequency modulation"

⭐ **The blocker cited against this is retired by citation:** the DJ report says ring mod "requires its
own audio-rate oscillator primitive … budget for that explicitly". `ChorusEffect.swift:239` is
`lfo += phaseIncrement`, per sample, inside `process()`, already RT-safe, already shipping. **An
audio-rate carrier is that accumulator with a larger increment.** Nothing to budget.

⚠️ **Scope note on the user's phrase.** "Frequency modulation" has three readings and only two are
here: **ring modulation** (this section) and **frequency shifting** (`.freqShifter`, rank 9, a Hilbert
network — genuinely new work). The third, **FM/PM synthesis**, is an *instrument* question and belongs
to `docs/research/2026-09-19-synthesis-engines.md` and the m39-b instrument-target work — explicitly
**out of scope here**, so that it is deferred deliberately rather than silently.

### 6.4.1 The struct and spec table

```swift
/// Ring modulator: input x band-limited carrier. The classic metallic /
/// bell / sci-fi voice, and the most dramatic sound per line of code in the
/// whole suite.
public struct RingModParams: Codable, Sendable, Equatable {
    public var carrierHz: Double
    public var mix: Double
    public var waveform: Double        // 0 sine, 1 triangle, 2 square, 3 saw
    public var inputHighCutHz: Double  // pre-filter, to control fold-back
    public var stereoSpreadDeg: Double // R carrier phase offset
}
```

| slot | name | range | default | unit | **curve** | **Modulatable** | why |
|---:|---|---|---:|---|---|---|---|
| 0 | `carrierHz` | 0.5 … 5 000 | 440 | Hz | **`.logarithmic`** | **yes** | 13 octaves. Smoothed internally per rule 6.0.6, and the oscillator's **phase is continuous across a change**, so a carrier step is a frequency step and never a phase discontinuity — that is what makes this `yes` instead of `warned` |
| 1 | `mix` | 0 … 1 | 0.5 | linear | `.linear` | **yes** | bit-exact dry at 0 |
| 2 | `waveform` | 0 … 3 | 0 | linear | `.linear` | **refused** (`discrete`) | `.rounded()` index |
| 3 | `inputHighCutHz` | 500 … 20 000 | 20 000 | Hz | **`.logarithmic`** | **yes** | default is effectively off |
| 4 | `stereoSpreadDeg` | 0 … 180 | 0 | deg | `.linear` | **yes** | default 0 keeps it mono-safe |

**Totals contributed: 4 yes, 0 warned, 1 refused.**

### 6.4.2 Aliasing — the honest answer, in two parts, because they are different problems

1. **The carrier's own harmonics must be band-limited.** A naive square or saw at 3 kHz aliases
   violently. **Frozen: `waveform` 1–3 are generated band-limited** (PolyBLEP for saw and square, an
   integrated band-limited triangle). A raw `sign(sin)` square is not acceptable and will sound broken
   in the demo before it sounds broken to a user.
2. **The PRODUCT's fold-back is inherent and is part of the sound.** Ring modulation produces `f ± fc`;
   whenever `f + fc` exceeds Nyquist it folds down. Classic hardware ring modulators do this and it is
   half their character. ⛔ **Do NOT oversample this effect to "fix" it** — that removes the sound
   people want it for. `inputHighCutHz` is the control given to anyone who wants less of it, and
   `fx.describe`'s `note` must say all of this in a sentence a novice can act on: *"High carrier
   settings on bright material produce clangorous fold-back tones — that IS the ring-mod sound. Pull
   `inputHighCutHz` down to around 4 000 Hz for a cleaner, bell-like result."*

---

# 7. Array params, booleans, and one-shot triggers — the ruling

The DJ report flags two proposals that "do not fit our numeric-only param surface" and routes them to
me: a `steps: [Double]` array for a trance gate, and a boolean `engage`. Both are settled here, and
**neither needs new machinery**.

## 7.1 `steps: [Double]` — it is not an effect param, and it already exists

⭐ **The premise is wrong, and checking it is what dissolves the problem.** The numeric-only constraint
is a property of **`EffectParamSpec`**, and it exists for one reason: **position in the spec array IS
the automation slot**, and `storeAutomatedParam(slot:value:)` takes a **scalar**. An array cannot have
a slot index, so an array cannot be an effect param. That reasoning is correct — **and it does not
reach modulation sources**, because:

- `mod.addSource` takes `params` as an **object** (modulation contract §7.1), backed by
  `ModulationSourceParams`, *"a per-kind struct with a custom `Codable`, NOT a `[String: Double]`"*
  (§7.6);
- modulation sources and routes carry **no positional indices at all** — §7.6 states it outright:
  *"Routes and sources are addressed by UUID, targets by name. The append-only slot law … does not
  reach this file — and must never be allowed to."*
- and `stepSequencer.steps` is **already in the frozen contract**: an array of numbers, each `-1…1`,
  length `1…64`, default `[1, 0, 1, 0]`, with `modulationStepsInvalid` already defined for an empty
  array, a length over 64, or a non-finite entry.

**Ruling, frozen:**

> **A pattern belongs to a modulation SOURCE, never to an effect parameter.** An effect that wants a
> per-step behaviour exposes a **continuous** parameter and lets a `stepSequencer` route drive it.
> No effect kind in this tree may carry an array parameter.

**Why the two alternatives lose, concretely:**

| alternative | why it loses |
|---|---|
| 32 indexed scalars `step0…step31` | 32 automation slots frozen forever, for a pattern whose most common edit is *changing its length*. `fx.describe` for that kind becomes 32 rows of noise an agent must read past. And a 48-step pattern is then impossible without a second append of 16 more. |
| a new pattern-typed param kind | Invents a second parameter surface — with its own validation, its own wire encoding, its own MCP schema, its own `describe` shape — to solve a problem the modulation contract solved last week. Two param surfaces is how the UI and the agent end up knowing different things, which is the defect m39-a exists to have fixed. |

## 7.2 A boolean `engage` — a `0…1` numeric param plus a `hold` automation lane

**Ruling, frozen:**

> A boolean is a `0…1` numeric parameter, on with `>= 0.5`, `Modulatable: refused`, reason `discrete`
> — the `gain.invertPolarity` / `limiter.truePeak` / `eq.*Enabled` precedent, unchanged. A **one-shot
> gesture** is that same parameter driven by an `automation.addLane` lane with the **`hold`** curve.
> There is no trigger verb.

`AutomationCurve` is `linear` or `hold` only (inventory §3.2) — and `hold` is exactly a step function,
which is exactly what an engage is. An agent writes:

```
automation.addLane { trackId, target: {kind:"effectParam", effectId, paramName:"freeze"},
                     points: [ {beat: 0, value: 0, curve: "hold"},
                               {beat: 16, value: 1, curve: "hold"},
                               {beat: 20, value: 0, curve: "hold"} ] }
```

**What this buys, and what it costs, stated precisely:**

- ✅ Reproducible, seek-exact, live-and-offline identical in *placement*, persisted in the project,
  visible in the automation UI, undoable — every property a hidden trigger would forfeit.
- ⚠️ **Quantum-accurate, not sample-accurate: the edge lands 0–10.7 ms late at a 512-frame block,
  averaging ~5.3 ms, and inconsistently edge to edge.** For `hallReverb.freeze` that is inaudible —
  a reverb freeze has no transient. **For a tape stop it is not** (its whole identity is the instant),
  which is one of the two reasons tape stop is deferred (§10.1). A sample-accurate engage needs the
  D8 position primitive, and it is deferred with it.

⛔ **Why not a `fx.trigger` verb.** It would put **hidden render-thread state** behind a wire call: the
same project would render differently depending on whether a verb had been called, offline renders
could not reproduce it, and an agent could not read back what it had done. The modulation design
rejected `mod.trigger` on exactly this reasoning (*"there is nothing to trigger … a verb that implies
hidden state would invite exactly the state this design exists to avoid"*), and a second exception
here would make that rejection arbitrary rather than principled.

## 7.3 `fx.applyGesture` — OUT of this milestone, and the reason is scope, not principle

The DJ report's takeaway 8 argues for a PRESET tier above raw params — `fx.applyGesture(kind:
"tapeStop" | "tranceGate" | …)` — on the grounds that a non-musician narrating intent is far better
served by one named call than by an agent guessing 5–8 DSP values. **The argument is good and I am not
rejecting it.**

**But it is out of THIS milestone (D11):**

1. It is consistent with one-command-surface **only if** it converges on `ProjectStore` — i.e. it must
   be a composition of existing store mutations, not a parallel path. That is buildable, and it is a
   real design, not a wrapper.
2. Every gesture it would bundle today is **either already a two-call sequence** (`mod.addSource` +
   `mod.addRoute`) **or an effect that does not exist yet** (tape stop, beat repeat). A preset tier over
   two calls and two absent effects is a verb in front of nothing.
3. ⭐ **A composite verb freezes a bundle.** Wire commands are additive-only and never renamed, so the
   *set of gestures* and the *shape of each gesture's params* become permanent on first commit. Doing
   that before the effects exist guarantees at least one gesture will be wrong forever.

**Filed as `m39-v`, weight M, route `mcp-integration-engineer`, with an explicit re-open condition:
when THREE gestures exist that each bundle four or more calls.** Until then the "preset tier" ships as
**skill prose and demo specs** — a documented call sequence an agent can copy, which is the same payoff
with none of the permanence.

---

# 8. What must NOT ship before m39-d

⛔ **The roadmap rule stands and this design does not relax it: no tempo-synced effect ships until
m39-d is measured.** What follows is only the mapping onto this suite.

## 8.1 The gate, restated accurately — because its premise was already corrected once

m39-d as originally filed says the live block *"has never been measured here."* ⛔ **That premise is
stale and has been corrected in place.** The divergence **was** measured at breath-pad P6 on
**2026-08-19** (`Sources/DAWCore/MIDIControllerRouting.swift` ~`:431-441`): a real `AudioEngine`
against this machine's default output reported **`quantumFrames = 512` at 48 kHz ⇒ 93.75 Hz**, with
`renderedFrames` an exact multiple of 512. `RenderBlockSize.swift` has since been corrected so the two
files agree.

**So the still-unmeasured question is narrower and different from the item's own wording:** *what
happens when the hardware buffer is NOT 512* — 64, 128, 1024, an aggregate device, BlackHole, a
user-changed buffer. **That** is what m39-d must measure, and it must
**positive-control the instrument by forcing a known-different buffer and proving the probe reports
the difference.** ⭐ A divergence probe that has never reported a divergence is indistinguishable from
a probe that cannot.

⚠️ **Check this premise before executing m39-d's method.** It is the same trap that produced the stale
filing: the record said X, the source said Y, and nothing compared them.

## 8.2 The mapping — which of my candidates are gated, and which are not

| item | tempo-synced? | **gated on m39-d?** | also needs m39-c? |
|---|---|---|---|
| `.djFilter` (§6.1) | no | ✅ **NO — ships first** | no |
| `.flanger` (§6.3) | no | ✅ **NO** | no |
| `.hallReverb` (§6.2) | no — **`preDelaySync` deliberately CUT from v1 to keep it so** | ✅ **NO** | no |
| `.ringMod` (§6.4) | no | ✅ **NO** | no |
| `.stereoWidth` / mono-maker | no | ✅ **NO** | no |
| `.phaser`, `.transientShaper`, `.freqShifter`, `.clipper`, Saturator v2, de-esser | no | ✅ **NO** | no |
| Tremolo / auto-pan / **free-Hz** gater presets (§3.2) | no | ✅ **NO** | no |
| ⛔ **Tempo-synced trance gate** (§3.3) | **yes** | ⛔ **YES** | ⛔ **yes** |
| ⛔ **`.tapeDelay` synced mode** | **yes** | ⛔ **YES** | ⛔ **yes** |
| ⛔ **`hallReverb.preDelaySync` append** | **yes** | ⛔ **YES** | ⛔ **yes** |
| ⛔ **Beat repeat, tape stop, vinyl brake, backspin, half-time, granular freeze** | **yes** | ⛔ **YES** | ⛔ **yes** |
| `.tapeDelay` **free-ms** mode | no | ✅ **NO** | no |

⭐ **Read the shape of that table: every single item in this milestone's build tier is ungated.** That
is not luck — it is the ranking criterion doing its job. The gate falls entirely on the rhythmic
family, and the rhythmic family's highest-value member (the trance gate) needs **no effect build at
all**, so the gate costs us prose and a preset, not engineering time.

## 8.3 m39-c sequencing — and the duplication it exists to prevent

**m39-c (generalise the tempo-sync resolver) is NOT BUILT.** The resolver is hardwired —
`guard effect.kind == .delay` (`Sources/DAWCore/DelayTempoSync.swift:36-37`) — and is invoked at
**five intake seams** (`OfflineRenderer.swift:272,274`; `AudioEngine.swift:1105`, `:2374`,
`:3925-3932`), plus a by-hand refusal in `Automation.swift:90-97` that names `.delay` explicitly to
stop a lane being drawn on a `sync`/`division` param.

⛔ **FROZEN PROHIBITION: no effect in this suite may hand-roll a second tempo-sync resolver.** Not a
`guard effect.kind == .tapeDelay` beside the existing one, not a private beats-to-samples conversion
inside an effect, not a "temporary" copy. **That duplication is the exact defect m39-c exists to
remove, and adding a second instance of it while the item to remove the first is open is how it
becomes permanent.** The modulation contract states the same prohibition for `mod.*` (§7.2.1); this
suite inherits it verbatim.

**Sequence, frozen:** `m39-c` → `m39-d` → anything in the ⛔ rows above. Nothing else in this document
waits on either.

---

# 9. Audibility — the demo plan, because the user is the listener

**The standing rule this section exists to satisfy:** ship **3–4 options differing on ONE axis each**,
never one result — **their pick IS the feedback**. The user is not a musician; their words *describe*,
they do not diagnose. And: **never ship a sound demo without checking it can BE heard** — if it cannot,
warn, or show it another way.

**Harness:** `node scripts/demos/render-variants.mjs scripts/demos/specs/<set>.json`, headless by
default. Each variant is a list of wire commands with `$binding` references; renders land in
`scripts/demos/out/<set>/` with a `manifest.json` of every measured number. **Exit 3 means the silence
positive control did not report silence and NOTHING WAS SCORED** — an exit 3 is not a soft failure.
⚠️ The harness's audibility guard already caught one byte-identical-variant failure; treat a pass as
information, not as decoration.

⭐ **Every effect below has a stated single axis. That is a design requirement, not a demo
requirement** — an effect whose value cannot be demonstrated by moving one number is an effect whose
controls are wrong, and §9.6 names the two in this suite that come closest to failing it.

## 9.1 The demo sets, one per shippable item

| set file | ONE axis | variants | what the user is being asked |
|---|---|---|---|
| `dj-filter-sweep.json` | **`resonance`** | 0.0 · 0.3 · 0.6 · 0.9 | An identical automated `position` sweep (−0.8 → +0.8 over 8 bars) in every variant; only resonance differs. *"Which sweep has the right amount of whistle?"* ⭐ **This is the primary DJ-filter demo** — the effect is a motion, so the demo must move. |
| `dj-filter-position.json` | **`position`** | −0.75 · −0.3 · +0.4 · +0.8 | Static positions on a loop. Secondary; proves tone, not gesture. |
| `hall-reverb-size.json` | **`sizeMeters`** | 3 · 12 · 30 · 55 | ⭐⭐ **THE demo of the whole milestone.** `decaySeconds` is **FIXED at 2.5 s in all four** — so if the space changes while the tail length does not, the listener has heard the exact thing `.reverb` structurally cannot do. |
| `hall-vs-freeverb.json` | **which kind** | `.reverb` roomSize 0.3 · `.reverb` roomSize 0.9 · `.hallReverb` size 8 · `.hallReverb` size 40 | The honesty demo: the two `.reverb` variants should differ in **tail length**, the two `.hallReverb` variants in **space**. It makes the §5.2 documentation audible instead of asserted. |
| `flanger-feedback.json` | **`feedback`** | −0.85 · −0.4 · +0.4 · +0.85 | Hollow/metallic vs ringing/resonant. The bipolar range is the whole point, so it is the axis. |
| `ringmod-carrier.json` | **`carrierHz`** | 40 · 180 · 700 · 2400 | Tremolo → growl → bell → clang. The most dramatic axis in the suite. |
| `trance-gate-pattern.json` | **the `steps` pattern** | 4 patterns, increasing busyness, identical everything else | ⚠️ Gated on m39-c + m39-d (§8). Also the set that proves the §3.3 send-bus derivation, with variant 4 as the route-disabled **positive control**. |
| `ducked-reverb-depth.json` | **compressor `ratio`** | 1:1 (control) · 3:1 · 6:1 · 12:1 | ⚠️ **Must render the ISOLATED REVERB BUS**, per the §3.1 measurement where the effect was 2.7 LU on the stem and invisible in the mix. Rendering the mix would demonstrate the feature's failure mode, not the feature. |
| `tremolo-rate.json` | **`rateHz`** | 0.8 · 3 · 6 · 11 | Ships with m39-e; free-Hz, ungated. |

## 9.2 The material, and why it is prescribed rather than left open

**Frozen: every set uses a source whose spectrum can actually show the effect.** Four defaults:

- **Filter, ring mod, flanger:** a sustained harmonically-rich source — a `polySynth` saw pad. A sine
  has nothing for a filter to remove and nothing for a ring modulator to multiply into sidebands, and
  a demo of a filter on a sine is a demo of a volume knob.
- **Reverb:** short, transient material with silence after it — a plucked or percussive phrase, **not**
  a pad. A pad masks its own tail, so a size change becomes inaudible. ⭐ This is the single most
  likely way the reverb demo gets built wrong.
- **Trance gate:** a sustained pad. A gate on already-rhythmic material demonstrates nothing.
- **Ducked reverb:** kick plus the reverb-bus'd source, per §3.1.

## 9.3 Loudness confound — the trap the audibility guard does NOT catch

The guard catches **byte-identical** variants. It does **not** catch four variants that differ only in
**level**, which a listener will reliably report as "the third one" for the wrong reason.

⛔ **Frozen: every variant in a set is loudness-matched to within 1.0 LU of the set's median
integrated loudness, and the manifest records each variant's measured value.** Three axes in this
suite will otherwise confound: `resonance` (adds peak energy), `mix` on any wet effect, and the
clipper's `ceilingDb` (which is *only* a loudness change). ⚠️ Measure with `ffmpeg -hide_banner` —
`-v error` suppresses `ebur128` and `astats`, which log at INFO, so the numbers you came for vanish
while the command looks like it succeeded.

## 9.4 The listening note that ships WITH each set

One short paragraph per set, in novice language, naming **what to listen for** and **what would make
it inaudible**. For example, for `ducked-reverb-depth`:

> Listen to the reverb tail *between* kick drums. In the deeper variants the tail ducks out of the way
> when the kick lands and swells back in the gap — a pumping breath under the beat. **If you hear no
> difference, the reverb is probably too quiet to hear ducking at all**: this is rendered from the
> reverb bus on its own for exactly that reason, and in a full mix the effect vanishes when the bus
> sits more than about 10 dB under everything else.

## 9.5 Demo obligations are per-item acceptance, not a milestone tail

⛔ **An item is not done until its demo set has been rendered and the harness exited 0.** A UI phase is
not done until someone has looked at it, and an audio phase is not done until someone has heard it. The
demo is how anyone hears it.

## 9.6 The two items that come closest to failing the single-axis test — named, not hidden

1. ⚠️ **`.stereoWidth` / mono-maker has a legible axis and an ILLEGIBLE LISTENING SITUATION.** The axis
   is `width` (or `crossoverHz`), but a width change can be **completely inaudible on a mono speaker or
   a laptop**, and this is exactly the case the audibility rule was written for. **Therefore: a width
   demo ships a measurement alongside the audio, not audio alone** — a mono-sum-difference figure per
   variant, which is `m23-dj`'s stated acceptance test anyway. **Show it another way, as the rule
   says.** And the listening note must open by naming the requirement: *"headphones or two speakers —
   on a single speaker these four files are close to identical by construction."*
2. ⚠️ **`.hallReverb`'s `diffusion` and `earlyLateBalance` have no novice-legible axis of their own.**
   That is a real limitation and it is not a reason to remove them — they are standard, they matter to
   the sound, and an agent can reason about them. **But they do not get their own demo set.** They ship
   as differences *between named presets* ("Tight Room", "Concert Hall", "Ambient Wash"), where the
   listener judges a whole character rather than a parameter they cannot name. Trying to demo
   `diffusion` as a single axis would produce four files a non-musician cannot tell apart, and that
   outcome would be read as "the effect does nothing" rather than "the axis was wrong".

---

# 10. Deferred, with their real cost named

Deferral is a decision and gets the same treatment as a build. Each of these is deferred **with its
blocker named**, so the next agent starts from the blocker instead of rediscovering it.

## 10.1 `m39-u` — the buffer-capture family (beat repeat, stutter, tape stop, vinyl brake, backspin, half-time)

⚠️ **This is the family the user's brief points at most directly — "used in loops, by DJs" — and it is
the one I am deferring. That is a deliberate trade and it should be argued with, not accepted
quietly.** The trade: these items need **two pieces of new infrastructure**, while everything in §6
needs none, and shipping four effects that work beats shipping one that needs a platform first.

**Blockers, both already specified above so the spike does not re-derive them:**
1. The capture ring buffer — §4.3, including the 3.07 MB-per-strip capacity decision.
2. Position inside `process()` — **D8**, whose real cost is the **publish-side anchor predicate**, not
   the protocol method.

Plus, for tape stop specifically, a **third**: a variable-rate resampling read, which is a fourth
consumer of `InterpolatedDelayLine` — ⭐ **so §4.1's extraction pays for part of this item too**, and
the spike should start by checking whether the home as built is wide enough (it will need
`cubicHermite`, and possibly a deeper interpolation order for a 36-semitone pitch drop).

**Route:** `daw-architect` spike, **then** `audio-dsp-engineer`. ⛔ **Gated on m39-c + m39-d.**

## 10.2 `m39-w` — granular freeze

**Deferred separately from `m39-u`, and the separation is the point.** "Buffer capture" describes both
in casual English and they need **different primitives**: beat repeat needs a ring buffer with a
retriggerable read head; granular freeze needs a **grain scheduler** — windowing, overlap-add,
per-grain pitch and pan, a grain-lifetime pool. Letting one spike absorb both is how a scoped spike
becomes an unscoped one. **Do `m39-u` first; decide `m39-w` afterwards with the buffer in hand.**

## 10.3 The pitch/time family — shimmer, pitch shifter, harmonizer, formant shift

⛔ **Do NOT re-litigate the engine choice.** `docs/research/2026-07-05-time-stretch-library-evaluation.md`
already selected **signalsmith-stretch (MIT)** with explicit formant controls. What is **unexercised**
is its documented real-time mode (`splitComputation`) — so the open question is *real-time
integration*, not *which library*. That changes the item's character from "new DSP research" to
"integrate an already-chosen library", which is a much smaller and much better-understood risk.

Everything in this family is deferred behind that one integration: shimmer (D10), pitch shifter,
harmonizer, formant shift / "duck the key", pitch-preserving half-time, turntable warp.

## 10.4 Items already filed — ADOPT the IDs, do not mint beside them

⚠️ **Precedent: `m27-n` duplicated `m26-a` and had to be merged.** Three of this domain's candidates
are already filed and carry constraints worth more than a fresh filing would:

| existing ID | candidate it covers | what its filing already carries |
|---|---|---|
| **`m23-dj`** | mono-maker / widener (my rank 5) | The user asked for *"true stereo"*, **not** a Haas/polarity trick. It specifies three honest approaches and makes **mono compatibility the acceptance test**, not a nice-to-have. Weight M. |
| **`m23-cl`** | dynamic EQ / multiband | *"The best-evidenced competitor gap in the audit"* — all five compared DAWs have one. **Requires a design spike before build commitment**: crossover topology and band count are render-thread shape decisions. Weight L. |
| **`m23-ci`** | dither on bit-depth-reduced export | Adjacent to `.clipper` / `bitCrusher`: our `bitCrusher` has a `dither` param and **the exporter does not**. |

## 10.5 Explicitly NOT deferred, and NOT in scope either

**The mix assistant.** The inventory verified that its DSP is not merely built but **already on the
wire** — `mixer_master_analysis`, `mixer_live_loudness`, `render_measure_loudness`, `reference_analyze`,
`reference_compare`, `frequency_reference`, `fx_spectrum` all ship today. It is plausibly the highest
value-per-token item in the whole programme.

⛔ **It is still not this milestone's work, and saying so is the point.** The user asked for
*instruments and effects with parameters and presets*. A mix assistant is **adjacent to that, not an
instance of it**. It should be offered as an option and never substituted for the plugin work that was
actually requested — a substitution is exactly how a brief gets quietly replaced by something the
agent found more interesting.

---

# 11. Implementation plan

⛔ **STOP — read §2 and §3 before you quote a cost from this section.**

This plan builds **four** new effect kinds. It is preceded by **four capabilities that cost nothing at
all**, and a reader who skims straight here and prices "creative effects" off the build legs below will
do **exactly the wrong thing**: build a trance-gate effect that already exists as a modulation route,
or a ducking parameter for a topology that was already rendered and measured working.

| already possible | cost | where |
|---|---|---|
| Ducked reverb (send + sidechained compressor) | **ZERO** — rendered and measured | §3.1 |
| Filter sweep on `eq.lowPassFreq` | **ZERO** — works today, reduced quality | §3.1 |
| Tremolo, auto-pan, free-Hz gater | **ZERO beyond m39-e** | §3.2 |
| Tempo-synced trance gate | **ZERO beyond m39-e + m39-c** | §3.3 |

⭐ **The DJ report ranks the trance gate #1 *to build*; the honest answer is that it is #1 *to
document*.** That sentence is the single most load-bearing conclusion in this document. The same shape
retired half of M32 once the engine was measured instead of assumed. **Leg 0 below exists to ship these
four first, before a line of DSP is written.**

## 11.0 The file set for ONE new effect kind — measured, not estimated

**The 6 mandatory switch sites** (the compiler forces every one; this is the irreducible cost):

| # | path | what changes |
|---:|---|---|
| 1 | `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/Effects.swift` | the `EffectDescriptor.Kind` case, the `<Kind>Params` struct, the descriptor's additive-optional field + `resolved<Kind>` + the `init` parameter, and the `EffectParamSpec.specs(for:)` arm |
| 2 | `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Effects/EffectFactory.swift` | one arm in `makeInstance(for:)` and one in `applyParams(_:to:)` |
| 3 | `/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/EffectEditorModel.swift` | the editor's param surface for the kind |
| 4 | `/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/MixerModel.swift` | strip/insert presentation |
| 5 | `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore.swift` | kind handling at the store boundary |
| 6 | `/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift` | `fx.add` kind parsing and `fx.describe` |

**Plus, and these are NOT optional even though the compiler will not force them:**

| path | what changes |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Effects/<Kind>Effect.swift` | **new** — the DSP |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWApp/Mixer/` | the insert view's label/icon for the kind |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWControl/CopilotCatalog.swift` | ⭐ **RULED: YES for a new effect KIND.** See 11.0.1 |
| `/Users/dsemenov/Views/daw-pro/mcp-server/src/server.ts` | the kind enum in `fx_add`'s schema + the tool description text |
| `/Users/dsemenov/Views/daw-pro/claude-plugin/skills/daw-wire-reference/SKILL.md` | the kind and its params |
| `/Users/dsemenov/Views/daw-pro/scripts/demos/specs/<set>.json` | **new** — the demo set (§9), and the item is not done without it |
| `/Users/dsemenov/Views/daw-pro/docs/ARCHITECTURE.md` | ⚠️ its "Wire surface — CURRENT TOTALS" ledger is **already four closes stale** (reads 204/209 against a measured 218/223, found at m39-f). Fix it while you are there or the drift compounds. |
| `/Users/dsemenov/Views/daw-pro/docs/ROADMAP.md` | tick the item |

**Blast radius, re-measured by me today rather than carried:** `bitCrusher` appears in **27 files**
across `Sources/`, `Tests/`, `mcp-server/src/`, `claude-plugin/` and `ARCHITECTURE.md` — 5 in
`DAWCore`, 3 each in `DAWEngine/Effects`, `DAWAppKit`, `DAWCoreTests`, `DAWControlTests`, 2 each in
`DAWControl` and `DAWEngineTests`, 1 each elsewhere. **Positive control: the same command shape on
`bassEnhancer` returns 25** — the grep works and the 27 is a count, not a coincidence. The inventory's
**29** counts a wider doc set (dogfood logs, ROADMAP) that I excluded; the two figures agree.
⚠️ **27 is NOT the cost of a new kind.** Most of those files use the kind as a test fixture or mention
it in prose and need no change for a new sibling. **The cost is 6 + the DSP + the demo.**

### 11.0.1 Ruling on `CopilotCatalog.swift`, because it is one skip away from becoming precedent

m39-f flagged this and asked for a ruling before it became a third consecutive skip. **The ruling:**

> **A new effect KIND updates `CopilotCatalog.swift`. A new describe/introspection VERB does not.**

The distinction is what the catalog is *for*: it is how the in-app copilot knows what capabilities
exist to suggest. A new effect is a capability a user would want suggested and cannot otherwise
discover; a `describe` verb is a tool the agent calls *once it already knows*. That keeps the m39-f /
m34-q precedent intact for verbs (so those two skips were correct, not debt) while closing the hole
for kinds. ⚠️ **This ruling covers effect kinds only** — the wider question m39-f raised about
describe-style verbs is adjacent and is **not** settled here.

## 11.0.2 ⭐ Item IDs: SETTLED — this work is filed into M39, not a new milestone

**RULED by the orchestrator 2026-09-19: re-letter into M39; do NOT mint M40.** The IDs below are
final and the document uses them throughout.

**Why.** **M39's own title is *"a modulation layer, creative FX, synthesis engines, and presets"*** —
the work this document plans is named inside M39's scope. Minting a new milestone for work an existing
milestone already claims is exactly the shape that produced the `m27-n` / `m26-a` duplicate this tree
is still carrying and still has to remember to merge.

⚠️ **I originally asked the wrong question** — *"does `m40-` collide?"* (it did not) — when the
question that decides it is *"does an existing milestone already claim this scope?"* (it does).
Recorded because the wrong question returned a clean, confident, useless green.

**The allocation, measured:** M39 already uses `a, a-2, b, c, d, e, f, f-2, g, h`, so this document
runs **contiguously from `m39-i`** in ranking order:

| this doc | id | | this doc | id |
|---|---|---|---|---|
| DJ filter | **`m39-i`** | | tape delay | **`m39-n`** |
| flanger | **`m39-j`** | | phaser | **`m39-o`** |
| echo-freeze range | **`m39-k`** | | transient shaper | **`m39-p`** |
| hall reverb (FDN) | **`m39-l`** | | freq shifter | **`m39-q`** |
| ring mod | **`m39-m`** | | … through | **`m39-ab`** |

⭐ **The 18-slot objection I raised dissolves — multi-letter suffixes are NORMAL CONVENTION in this
tree, not an exception.** Verified first-hand: `m23-aa` through `m23-ah` all exist, as do sub-lettered
forms like `m23-ab-1`, `m23-ac-1` and `m23-ac-2a`. So `m39-z` is followed by `m39-aa`, `m39-ab`, and
nothing about that is special.

⚠️ **Counting note, because it bit me here too.** I first reported these IDs as appearing "32 times";
that was `grep -c`, which counts **LINES, not occurrences**. The true occurrence count was **42** —
several lines carry more than one ID. The rename was done by occurrence and verified with a positive
control (zero surviving `m40-[a-t]`, and `m39-i`/`m39-ab` both returning hits, so a broken pattern
could not masquerade as a clean rename).

⛔ **`docs/ROADMAP.md` is the orchestrator's file. This document does not touch it** — filing happens
from here, by them.

## 11.1 The order, with gates between the legs

**Leg 0 — zero-risk documentation and presets, ships immediately, no DSP.**

| id | item | weight | route |
|---|---|---|---|
| `m39-i` | Ducked-reverb preset + the "it vanishes in a quiet bus" warning (§3.1) + `ducked-reverb-depth.json` | S | `mcp-integration-engineer` |
| `m39-j` | The honest filter-sweep paragraph — what `eq.lowPassFreq` + `automation.addLane` does and does not give you (§3.1) | S | `docs-scribe` |
| `m39-m` | `.reverb`'s honest `note` text, in **both** `EffectParamSpec.specs(for: .reverb)` and the MCP tool description (§5.2) | S | `docs-scribe`, verified by `qa-test-engineer` |
| `m39-k` | Widen `DelayParams.feedbackRange` to `0...1.0` for echo freeze, with the stability note (§3.1) — ⚠️ **SHIPPED AT `0...0.999`; `1.0` diverges, measured. See ERRATUM E11** | S | `audio-dsp-engineer` |

⭐ **Leg 0 delivers three of the domain's named gaps before one line of DSP is written.** Do it first;
it is also the cheapest way to find out whether the user actually wanted what we think they wanted.

**Leg 1 — the primitive, alone.**

| id | item | weight | route |
|---|---|---|---|
| `m39-j-0` | Extract `InterpolatedDelayLine` (§4.1), migrate `ChorusEffect`, **byte-identical render gate with its own positive control** | M | `audio-dsp-engineer` |

⚠️ **Id erratum, 2026-09-19.** This row said `m39-n` when written. By the time it was filed, `m39-n`
was already spent in `docs/ROADMAP.md` on the remaining-suite bucket, so the extraction is filed there
as **`m39-j-0`** — directly above `m39-j`, the item it blocks, because a prerequisite recorded anywhere
the picker does not arrive is not a prerequisite. The roadmap id is authoritative; the contract in §4.1
is unchanged.

⛔ **GATE: the byte-identical chorus render must be green, and the gate must have been shown to
redden**, before Leg 2 starts. Nothing else in Leg 1.

**Leg 2 — the new kinds, in payoff-per-cost order.**

| id | item | weight | route | depends on |
|---|---|---|---|---|
| `m39-o` | `.djFilter` (§6.1) | M | `audio-dsp-engineer`, UI by `ui-design-engineer` | — |
| `m39-p` | `.flanger` (§6.3) | S | `audio-dsp-engineer` | `m39-n` |
| `m39-q` | `.hallReverb` (§6.2) | L | `audio-dsp-engineer` | `m39-n` |
| `m39-r` | `.ringMod` (§6.4) | S | `audio-dsp-engineer` | — |
| `m23-dj` | mono-maker / widener — ⚠️ **ADOPT, do not mint** (§10.4) | M | `audio-dsp-engineer` | — |

⚠️ **`m39-q` is the one item here that should be split across two agent runs** — the FDN core plus
absorption first, tail modulation and `freeze` second — because an L-weight DSP item in one run is how
an agent hits the 600 s liveness watchdog. Brief it to **narrate**, to **persist per unit to disk**,
and to **grep-then-read-narrow** rather than reading `ProjectStore.swift` (472 KB) or `Commands.swift`
(764 KB) whole.

**Leg 3 — after m39-c and m39-d, and not before (§8).**

| id | item | weight |
|---|---|---|
| `m39-l` | Tempo-synced trance-gate preset + the send-bus render proof + `trance-gate-pattern.json` | S |
| `m39-aa` | `.tapeDelay` — free-ms mode may ship in Leg 2 if capacity allows; **synced mode is Leg 3** | M |
| — | `hallReverb.preDelaySync` / `preDelayDivision` append | S |

**Leg 4 — later, filed, sequenced, not scheduled.**

`m39-x` `.phaser` (S-M) · `m39-y` `.transientShaper` (M — **price the detector, not the shaper**) ·
`m39-z` `.freqShifter` (M-L) · `m39-s` `.clipper` + `Oversampler` (M) · `m39-t` Saturator v2 +
**Oversampler extraction** (M) · `m39-ab` de-esser (S-M) · `m39-u` buffer-capture **spike** ·
`m39-v` `fx.applyGesture` · `m39-w` granular freeze · `m23-cl` dynamic EQ (**adopt**) ·
`m23-ci` export dither (**adopt**).

## 11.2 Standing constraints every agent on this work must be briefed on

Not optional, and not inferable from the task:

- **Commits ONLY on the user's word.** No `git checkout` / `stash` / `restore` / `clean` — ever, and
  especially not over untracked work.
- **Control port 17600 is the user's LIVE app. Never touch it.** Staging is 17695, killed
  **pidfile-exact**, never `pkill`/`pgrep`. ⚠️ Identify a listener **by port**
  (`lsof -nP -p <pid> | grep -i listen`), **never by path** — any binary without a pidfile can *be*
  the live app, and a missing pidfile means you do not know whose it is, not that it is yours.
- **`./scripts/test.sh`, never bare `swift test`.**
- ⚠️ An `audio-dsp-engineer` is **concurrently in `Commands.swift`, `ProjectStore.swift` and
  `AutomationRenderer.swift` for m39-e.** Coordinate, cite by symbol rather than by line, and expect
  those three files to move under you.
- ⚠️ **No `timeout(1)` on this machine.** `timeout 60 foo` fails with *command not found* and looks
  exactly like an empty result.
- ⚠️ **Never pair `2>/dev/null` with a command whose EMPTINESS you intend to interpret**, and when an
  absence confirms your hypothesis, **positive-control it** — run the same command shape against
  something you know exists and show it can return non-zero.
- ⚠️ `grep -r` over `scripts/` hangs (`ace-step/` is ~56 GB) — always
  `--exclude-dir=ace-step --exclude-dir=rvc --exclude-dir=node_modules`.
- ⚠️ **`ffmpeg -v error` suppresses `ebur128`/`astats` summaries** (they log at INFO). Use
  `-hide_banner` when those numbers are the point.
- ⛔⛔ **DSP LAW — `InterpolatedDelayLine` carries NO denormal flushing, and a FEEDBACK caller MUST
  add its own.** The code being extracted comes from `ChorusEffect`, which states outright that *"the
  chorus path is feedback-free (taps only), so it can neither generate denormals nor blow up on finite
  input"* — so it has **never needed** denormal handling and contains none. **Three of its four new
  callers ARE feedback structures**: the flanger (§6.3), the tape delay, and the FDN's recirculating
  lines (§6.2). A decaying feedback path is precisely where denormals appear, and denormal arithmetic
  can cost 100x. **Frozen: the flush belongs to the CALLER, not to the home** — a line that flushed
  internally would tax every tap-only caller forever to protect callers that must handle it anyway.
  Match `DelayEffect`'s existing treatment (`:21`, implemented at `:217-218`); the pattern is
  house-wide (9 files in `Sources/DAWEngine/Effects/` mention denormals). **Full reasoning: §4.1.**
- ⚠️ **`grep -c` counts LINES, not OCCURRENCES — and blast-radius numbers in this document are
  file counts, not edit counts.** This bit me twice while writing: I reported these item IDs as
  appearing "32 times" when the true occurrence count was **42**. If you are counting call sites to
  size a change, count occurrences (`grep -o … | wc -l`), and positive-control the pattern.
- **A net test-count delta hides a shrink: every agent must NAME any test it retires.**

---

# 12. Test strategy

Nine gates. Every new kind must pass all nine; the first three are where this design is most likely to
be broken quietly.

| # | gate | shape, and its positive control |
|---:|---|---|
| 1 | **Byte-identical chorus render across the `InterpolatedDelayLine` migration** (`m39-n`) | Render a chorus project before and after; compare bytes. ⭐ **Positive control: perturb `depthMs` by a hair in a throwaway run and watch the comparison redden.** A byte comparison that has never failed is indistinguishable from one that cannot. |
| 2 | **Render-path allocation gate — ABSOLUTE ZERO, not a delta** | The `InsertSpectrumChainTests` shape: instrument the chain walk with the new kind in it and assert zero malloc/free events. ⚠️ Use `while` loops, not `for i in 0..<n` — at `-Onone` a `Range` iteration alone raises ~2 events per iteration (`EffectChainProcessor.swift:402-412`), which is why this gate can assert an absolute zero at all. |
| 3 | **Automation-slot order pin, per kind** | Assert `EffectParamSpec.specs(for: .<kind>).map(\.name)` equals a literal golden array **in the test file**. ⭐ This is the gate that makes the append-only law enforceable instead of aspirational: inserting a param in the middle reddens it immediately, instead of silently re-pointing every saved lane on that effect. **Every kind in §6 ships with one.** |
| 4 | **Param-spec conformance** | The existing `ParamCurveConformanceTests` must cover the new kinds: `multiplicativeCurvesHaveAPositiveLowerBound` over every new table, plus `defaultValue` inside `range` and `unit` non-empty. |
| 5 | **`Modulatable` totals + superset invariant** | Extend the modulation design's §6.2 totals test (**31 / 18 / 15 = 64 over 11 kinds** today) with each kind's contribution — `.djFilter` **4/0/1**, `.hallReverb` **12/1/1**, `.flanger` **6/0/0**, `.ringMod` **4/0/1**. And assert mechanically that **modulation refuses a superset of what automation refuses**. A new param with no verdict must fail loudly. |
| 6 | **Describe/settable bijection — a BEHAVIOURAL gate, not a source-shape one** | ⭐ The m39-f shape, which found a real 24th parameter: provoke a live `rejectUnknownKeys` refusal, **parse the "valid keys are …" list out of the error message**, and assert it equals the set `fx.describe` reports. A param added to one side and not the other fails. **A spy gate beats a source-shape gate** — a test that greps the source cannot catch a divergence between what the source declares and what the running app accepts. |
| 7 | **Persistence: byte-identical on disk for pre-existing projects** | Encode a project saved before the kind existed, after the change; assert the bytes are unchanged (the new descriptor field is `nil` and therefore **omitted**, the `startOffsetSeconds` precedent). ⭐ **Positive-control it the way m39-g was: set one new field non-neutral and watch the comparison redden.** |
| 8 | **Determinism + PDC** | Two renders from the same transport position are **bit-identical**. `latencySamples == 0` for every kind in §6 (rule 6.0.9) — and when `Oversampler` arrives, its latency must be **measured and compensated**, pinned the way m25-n pinned hosted-AU PDC (0 samples residual, falsifiability proven by planting a wrong latency and watching four cases redden at exactly their own values). |
| 9 | **DSP correctness, per kind, with measured numbers** | `.djFilter`: −3 dB at `cutoffHz(atPosition:)` ±2 %, 24 dB/oct slope measured across a decade, bit-exact dry at `position == 0`. `.hallReverb`: measured RT60 within 10 % of `decaySeconds`; **`sizeMeters` changes echo density with `decaySeconds` held — the test that proves the feature exists**; `highDecayMultiplier 0.1` measurably shortens the HF tail. `.flanger`: notch positions at `1/(2·delay)` odd multiples; `delay > 0` asserted across the whole `depthMs` range (the §6.3.2 bug, pinned). `.ringMod`: sidebands at `f ± fc` present and the carrier absent from the output (a ring modulator that leaks its carrier is an amplitude modulator). |

**Plus, every leg:**

- `./scripts/test.sh` — **8043 / 717 / zero failures** is the last measured Swift baseline (m39-f,
  2026-09-19). ⚠️ Re-measure; do not carry. **De-duplicate failing test NAMES — an issue count and a
  failure count are different numbers, and counting ✘ lines conflates them.**
- `node scripts/gates/doc-count-drift.mjs` — **exit 0**. ⭐ **And for §6.1–§6.4 the command count must
  be UNCHANGED**, because new kinds ride `fx.add` / `fx.setParam` / `fx.describe` and add no verb
  (rule 6.0.11). **A changed count after a §6 item means something was added this contract did not
  authorise** — that is a usable tripwire, so use it rather than just checking the exit code.
  ⚠️ `grep -c 'registerTool('` **lies**; the real pins are the `Reference commands` suite and MCP's
  bijection test.
- `node scripts/demos/render-variants.mjs …` — **exit 0** for the item's set (§9.5). Exit **3** means
  the silence positive control failed and **nothing was scored**.
- ⛔ **A `/plugin update` is owed** once these land, and the bundle must be **regenerated and
  stdio-verified first** (new kind present; a known-absent control absent). A bundle that is stale at
  regeneration time ships an announcement without its feature — which has happened here before.
  ⚠️ The path is `claude-plugin/.claude-plugin/plugin.json`, **not** `claude-plugin/plugin.json`.

---

# 13. For `docs/ARCHITECTURE.md` — "Key future decisions"

✅ **APPLIED to `docs/ARCHITECTURE.md` 2026-09-19** — appended to the "Key future decisions" section,
additively, on the orchestrator's instruction. **Do NOT paste it a second time.** Verified: 7 entries
present, the pre-existing `view.*` entry and the file's prior tail both intact, section heading
unduplicated. The applied text is expanded from the block below (house bullet style, with the losing
alternatives named); this block is retained as the record of what was settled.

**Seven decisions this document settles**, each stated so it can be argued with rather than merely
obeyed:

> - **Creative effects that are MOTION ride the modulation layer; creative effects that are DSP get a
>   kind.** The trance gate, tremolo and auto-pan are `mod.*` routes onto `.volume`/`.pan` (evaluated
>   **per sample**, so their edges are sample-accurate) — **not** effect kinds. The DJ filter, flanger,
>   FDN reverb and ring modulator are genuinely new DSP and get kinds. Settled
>   `docs/design/2026-09-19-creative-effects.md` §2, §3.
> - **A pattern belongs to a modulation SOURCE, never to an effect parameter.** `EffectParamSpec` is
>   numeric-only because position **is** the automation slot; modulation sources are UUID-addressed and
>   carry a typed `params` object, where `stepSequencer.steps` already lives. **No effect kind in this
>   tree may carry an array parameter.** §7.1.
> - **A boolean is a `0…1` numeric param; a one-shot gesture is that param on a `hold` automation
>   lane. There is no trigger verb**, because one would put hidden render-thread state behind a wire
>   call and make offline renders irreproducible. Cost: the edge is quantum-accurate (±10.7 ms), which
>   is fine for a reverb freeze and **not** fine for a tape stop. §7.2.
> - **`.reverb` is left alone and documented honestly, not deprecated.** `roomSize` is a verified
>   mislabeled decay control frozen at automation slot 0 forever; the real size control arrives as the
>   additive `.hallReverb` (8-line FDN). A Dattorro plate becomes a `topology` **mode** on that kind
>   **iff** its delay-line budget fits the FDN's prepare-time allocation — a rule, decided on a
>   measurement at plate-build time. §5.
> - **One primitive is extracted (`InterpolatedDelayLine`), one is declared-but-not-built
>   (`Oversampler`, extracted at its SECOND caller), one is deferred with its effects (the capture ring
>   buffer).** The extracted home is a **delay line, not a modulated delay line** — depth and rate stay
>   in the caller, which is precisely how a reverb tail modulator and a tape wow share it without
>   either being forced into the other's ranges. §4.
> - **New creative effects smooth their own derived state internally.** Effect params arrive as one
>   scalar per quantum and that is not changing — the `(start, end)` ramp interface was priced at 21
>   files and declined. So a `yes` modulatable verdict on a new kind is **earned by internal
>   interpolation** (frozen shape: per-sample linear across the quantum, coefficients every 32 frames),
>   not assumed. `eq` predates the rule; nothing new inherits its excuse. §6.0.6.
> - **Position is not available inside `process()`, and the API to deliver it is frozen but unbuilt.**
>   `EffectRendering.process` and `EffectChainProcessor.process` carry no timestamp; the
>   `AudioTimeStamp` lives one level up in `ChainHostAU`'s render block. The delivery shape is an
>   additive default-inert `storeRenderPosition(_:samplesPerBeat:)`. **Its real cost is the publish-side
>   anchor, not the protocol method** — `quantumStart` needs a published `AutomationSchedule`, and a
>   strip with neither lanes nor routes would have none. ⭐ **Measured at review: m39-e has ALREADY built
>   the anchor-only publish** (`AutomationSchedule.build(… requireAnchor:)`, whose own comment says it
>   exists because *"a MODULATION ROUTE has no points but still needs the schedule's ANCHOR"*), gated on
>   `modulatesVolume || modulatesPan`. So the remaining cost is **widening one boolean**, not building a
>   mechanism. Nothing in the creative-FX legs needs it; the buffer-capture family does. §4.3.

**Also owed to that file, found in passing and not introduced here:** its "Wire surface — CURRENT
TOTALS" ledger reads **204/209** against a measured **218/223** — four closes stale, spanning
untouched milestones (first spotted at m39-f).
