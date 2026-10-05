# Modulation systems, mod matrices, and macro controls — architecture recommendation

Research sprint, 2026-09-19. Scope: design the shared modulation layer DAW Pro is missing
(no LFO, no envelope follower, no step sequencer, no macro, no routing matrix of any kind
today), so that a sibling DJ/loop-effects report can build most of its domain on top of it.
**This report's single most important output is the recommended architecture in §3**, with
§7 a required, measurement-driven course correction to the RT design added mid-sprint.

No code was touched. Grounding was done by reading the actual source, not by assuming
convention: `Sources/DAWCore/Effects.swift` (`EffectParamSpec`, `EffectDescriptor.Kind`),
`Sources/DAWCore/Automation.swift` (`AutomationTarget`, `AutomationLane`),
`Sources/DAWEngine/Automation/AutomationSchedule.swift` (how automation actually reaches the
render thread), `Sources/DAWEngine/Instruments/PolySynthInstrument.swift` (the RT-safe
snapshot-publish pattern already in production), `Sources/DAWCore/Sidechain.swift`
(`SidechainGraph`), `Sources/DAWCore/TempoMap.swift` (`NoteDivision`), the `fx.*` /
`automation.*` verbs in `Sources/DAWControl/Commands.swift`, and — added for §7 —
`Sources/DAWCore/RenderBlockSize.swift`, `Sources/DAWCore/EffortField.swift`,
`Sources/DAWCore/MIDIControllerRouting.swift`, `Sources/DAWEngine/MIDISchedule.swift`, and
`Sources/DAWEngine/InstrumentSourceNode.swift`.

## 1. What we already have, precisely

- **`EffectParamSpec`** (`Sources/DAWCore/Effects.swift:929`) is the single source of truth
  for every effect parameter: `name`, `range: ClosedRange<Double>`, `defaultValue`, `unit`
  (a free string — `"linear"`, `"dB"`, `"Hz"`, `"s"`, `"ratio"`, `"%"`), and an optional
  teaching `note`. Its own doc comment names the convention this report leans on repeatedly:
  `note` exists for "params whose numeric surface hides extra semantics (nil-means-off
  filters, 12/24 slope snapping, 0/1 band bypass)" — i.e. **a numeric range standing in for
  an enum is already this codebase's idiom**, not something this report invents. It has
  **no scale/curve hint** — flagged as a gap in §5.
- **`AutomationTarget`** is a closed enum: `.volume`, `.pan`, `.sendLevel(sendID:)`,
  `.effectParam(effectID:, paramName:)`. It resolves to a `ClosedRange<Double>` via
  `valueRange(in:)`, and it is *already* the wire/disk shape
  (`{type, sendId?, effectId?, param?}`) shared by `automation.addLane` and persistence —
  the exact shape a modulation-route "destination" should reuse verbatim rather than
  reinvent.
- **`AutomationSchedule`** shows exactly how a resolved value reaches the render thread, and
  it settles two design questions this report would otherwise have to guess at:
  - Volume/pan automation is baked to **absolute sample-domain breakpoints** at schedule-build
    time (`buildBreakpoints`, tempo math done main-actor-side against `TempoMap`) and reaches
    the render thread through the **mixer node's** `volumePoints`/`panPoints` cursor
    evaluation — a *different* intake than the one below.
  - **Effect-param automation is resolved once per render quantum**, not per sample:
    `AutomationRenderer.storeEffectParams` calls `storeAutomatedParam(slot:value:)`
    "BEFORE the quantum" (`EffectRendering.swift:32`), and each built-in effect pokes a
    plain preallocated params copy from that one call. This is the load-bearing precedent
    for the modulation layer: **modulation on effect params should resolve at the same
    block-rate cadence**, not per-sample. §7 revisits this precedent under measured
    evidence and splits it into two tiers rather than accepting it uncritically.
  - **The cursor evaluator itself, `AutomationSchedule.value(at:points:cursor:)`, already
    accepts an arbitrary absolute sample time `t`** — it is not limited to block-start
    times. The current block-rate cadence is a choice made by its *caller*
    (`AutomationRenderer`, once per quantum), not a limitation of the evaluator. This
    matters a great deal for §7.2.
- **Tempo sync is already solved once, and the solution is "do the math off the render
  thread."** `DelayEffect.storeAutomatedParam` (`Sources/DAWEngine/Effects/DelayEffect.swift:155`)
  says it outright: `sync`/`division` are "control-plane-only (tempo math never runs here)"
  and lane creation on them is refused at the model level
  (`AutomationTarget.valueRange`, `Automation.swift:90-97`) because a lane would be a silent
  dead lane. The delay's `timeMs` arriving at the render thread "already IS the
  tempo-derived effective time when synced" — resolved at "the engine intake seams." A
  tempo-synced LFO must follow the identical shape: resolve `NoteDivision → periodSeconds →
  phaseIncrement` main-actor-side whenever tempo or division changes, republish, and let the
  render thread do a plain phase accumulator.
- **`NoteDivision`** (`TempoMap.swift:266`) is `1/1…1/32`, straight/dotted/triplet, raw-value
  strings `"1/4"`, `"1/8d"`, `"1/8t"`. The task's brief asks for 1/64 — that's one clean
  additive case (`sixtyFourth = "1/64"`, `...Dotted`, `...Triplet`), not a new encoding.
- **`SidechainGraph`** (`Sources/DAWCore/Sidechain.swift`) already does exactly what an
  envelope follower's cross-track "key input" needs: cycle detection (`cyclePath`), source
  validity (source tracks only, no bus sources), and it's the one place that answers "would
  this new key edge create feedback?" An envelope-follower modulation source should be
  **built as a second consumer of `SidechainGraph`**, not a parallel graph.
- **The RT-safe publish pattern already exists in production**, and it's the one to reuse
  verbatim: `PolySynthInstrument` (`Sources/DAWEngine/Instruments/PolySynthInstrument.swift`)
  publishes an immutable parameter snapshot through a heap-allocated `daw_atomic_ptr`, tagged
  with a monotonic `generation`; the render thread adopts a new snapshot only at the top of a
  quantum, recomputes derived coefficients only on generation change, and retired snapshots
  are kept alive ≥ 1 s on the main actor before release so an in-flight render callback can
  never touch freed memory. `AutomationSchedule`/`AutomationRenderer` use the same shape for
  breakpoint arrays, and `MIDIEventSchedule` (§7.2) uses it for note/CC events.
- **`MIDIEventSchedule`** (`Sources/DAWEngine/MIDISchedule.swift`) already carries
  sample-accurate, in-block event offsets (`ScheduledMIDIEvent.sampleTime`, relative to the
  schedule anchor), and `InstrumentSourceNode` already computes a per-quantum *slice* of such
  events (`windowEnd`, `cursor`, `events[end].sampleTime < windowEnd`) and hands that slice
  into a single `render()` call. This is the existing precedent §7.2 builds the event-rate
  modulation tier from.
- **The existing "additive field, never reorder" discipline**: `GainEffect`'s
  `invertPolarity` param was appended after `gainLinear` specifically so automation slot
  indices never move (`Effects.swift:972-990`, m38-a); EQ's `highPassFreq`/`highPassSlopeDbPerOct`
  were appended after the original 10 params for the same reason (m22-a). Any schema
  extension this report proposes (a `scale` hint on `EffectParamSpec`, a 1/64 `NoteDivision`
  case) must follow that same append-only rule.

## 2. Modulation sources — what exists in the wild, and what each buys us

| Source | Shape/behavior | Who ships it well | Notes for DAW Pro |
|---|---|---|---|
| **LFO** | Sine/tri/saw/square/S&H/random-smooth/custom-drawn; uni/bipolar; free-run, tempo-sync, key-retrigger, one-shot ("envelope mode"); phase offset; fade-in | Ableton's `LFO` M4L device (up to 8 destinations per instance) [[Ableton Max for Live Devices]](https://www.ableton.com/en/manual/max-for-live-devices/); FabFilter's `XLFO` object model (add as many as needed, drag onto any param) [[FabFilter Timeless 3 — XLFO]](https://www.fabfilter.com/help/timeless/using/xlfo) | Our highest-payoff single source. Covers tremolo/autopan/wobble/vibrato. **Control-rate tier — §7.** |
| **Envelope generator** (ADSR/DAHDSR/MSEG, loopable) | Multi-stage, some loop a sub-range for LFO-like behavior at slow rates | Alchemy/Zebra-class MSEGs [[Apple — multi-segment envelope]](https://support.apple.com/guide/logicpro/multiple-segment-envelope-controls-lgsica2ce73e/mac); Vital's envelopes | PolySynth already has ONE ADSR (amp only) — a general modulation-layer envelope is a *second*, freely-routable one, not a replacement. **Control-rate tier**, except its one-shot trigger edge itself is event-rate (§7.2). |
| **Envelope follower** | Tracks incoming audio amplitude (peak/RMS, attack/release) and outputs a control signal | Ableton's `Envelope Follower` M4L device [[Ableton]](https://www.ableton.com/en/manual/max-for-live-devices/); this is literally how sidechain pumping/ducking is built when you don't want a compressor's knee/ratio behavior | **This is our sidechain mechanism generalized.** Reuses `SidechainGraph` for the cross-track key tap; the "compressor" becomes just one possible destination (gain) among many (filter cutoff, reverb send, anything). **Control-rate tier.** |
| **Step sequencer / pattern modulator** | N steps (2–64 typical), per-step value, shape generators, forward/backward/ping-pong, sync to transport, optional per-voice/per-note | Bitwig's `Steps` modulator [[Polarity — Steps guide]](https://polarity.me/posts/bitwig-guides/2022-08-08-steps-bitwig-modulator-guide/) | Drives trance-gates and rhythmic filter/volume patterns; naturally reuses `NoteDivision` for step length. **Event-rate tier — §7.1/§7.2 — the one source kind a single block-rate design demonstrably cannot serve.** |
| **Random/chaos** | Sample & hold, smoothed random ("random-smooth" LFO shape), drunk-walk/Perlin-style continuous wander | Bitwig's `Random` modulator (poly or mono, "each note or voice can have its own character") [[Polarity — Random]](https://polarity.me/topics/random-modulator/) | Cheap, high perceived-organic-ness payoff; implementable as one more LFO "shape" rather than a separate source kind. **Control-rate tier**, unless used unipolar/stepped as a de-facto gate (then event-rate concerns apply). |
| **MIDI sources** | Velocity, aftertouch/channel pressure, mod wheel (CC1), key-track, MPE per-note dimensions | MPE ratified as an official MIDI 1.0 extension, Jan 2018: five expressive dimensions — Strike (velocity), Glide (per-note pitch bend, default ±48 semitones via per-channel routing), Slide (CC74 timbre), Press (channel pressure), Lift (release velocity) [[MIDI.org — MPE]](https://midi.org/mpe-midi-polyphonic-expression) | These are **per-voice by nature** — they belong to `PolySynthInstrument`'s internal world, not the track-level route graph (see §4). PolySynth today only honors pitch-bend and sustain (CC64); velocity currently scales voice amplitude directly, not through a routable matrix. |
| **Audio-rate modulation** (FM/RM between generators) | Sample-accurate; changes timbre, not just level/pitch/cutoff slowly | Phase Plant: "audio-rate frequency, phase and ring modulation... effortlessly brought into play between Generators, filters and distortion" [[Kilohearts — Phase Plant]](https://rekkerd.org/kilohearts-announces-phase-plant-hybrid-modular-synth-with-snapin-integration/) | **Explicitly out of scope for the track-level layer** (§8) — a third tier beyond both of §7's, needing per-sample resolution neither tier gives it. Note as a v2/instrument-internal-only idea. |

## 3. Routing architectures — the verdict

Four models, compared on the criterion this project actually needs most: **can an LLM agent
over a JSON wire protocol enumerate, address, and reason about this without ambiguity?**

**(a) Fixed/hardwired slots** ("LFO1 routes only to filter cutoff"). Simplest possible JSON
surface — an enum. Rejected as the base layer: it can't add a second LFO on the same
destination, can't generalize across eleven very different effect kinds plus a synth, and
boxes the AI into whatever combinations were hand-imagined ahead of time. (This is
approximately what PolySynth has *today* — one ADSR hardwired to amplitude — and it is
exactly the thing this report is asked to fix.)

**(b) A dense N×M mod matrix** (source rows × destination columns, depth per cell — the
Oberheim Matrix-12 model). Maximally legible as a *mental model*: "describe modulation" is
trivially "the matrix." But destinations here are unbounded and dynamic — any parameter on
any effect on any track, plus master — so a literal dense matrix is mostly empty cells and
doesn't fit fixed RT preallocation. Verdict: **keep this as the read-side view, not the
storage.**

**(c) Drag-and-drop-per-parameter modulation** (Serum/Vital/Bitwig): each destination
parameter carries a **list of {source, depth, curve} tuples**; sources are drag-dropped onto
knobs, and a matrix panel (when shown) is just a table view computed over the same list.
Serum ships *both* a literal mod matrix panel and drag-and-drop onto knobs — "dragging a mod
source to a knob will appear in the matrix, or vice-versa" [[Serum manual via search
digest]](https://s3.amazonaws.com/decembercymatics/Serum_Manual.pdf) — because they are the
same underlying list, presented two ways. Vital's is the same shape: "click a modulation
source... and drag it onto any parameter... a visual indicator shows exactly how much
modulation is being applied" [[Vital via search digest]](https://theproducerschool.com/blogs/music-production/serum-2-vs-vital-the-ultimate-wavetable-synth-comparison-2025).
Bitwig: "every parameter... can be modulated by anything else... you can stack as many
modulators on the same parameter as you want" [[Dubspot — Bitwig 2026]](https://blog.dubspot.com/bitwig-studio-dubspot-first-look).

**(d) A full modular graph** (Bitwig's Grid, Phase Plant's modulation pane): sources can
modulate *other sources*, utility nodes (math, scale, mix, quantize) sit between them,
arbitrary topology. Maximal expressivity, but an arbitrary graph **has no flat, stable,
enumerable description** — "describe all modulation on this track" becomes a graph
traversal that must guard against cycles, every new utility-node type is a new schema the
agent has to learn, and it is a materially larger engineering lift (canvas UI, cycle
detection, per-node RT scheduling). This is a power-user destination, not a v1 base layer.

### Verdict: (c), with (b) as the computed view, and NOT (d) for v1

Build modulation **sources** as first-class UUID'd objects living on a track (the `Effect`
precedent — `Sources/DAWCore/Effects.swift`), and modulation **routes** as first-class
UUID'd objects of the shape `{id, sourceID, target: AutomationTarget, depth, curve?}` (the
`AutomationLane` precedent — one object per destination, `Automation.swift:151`). "Describe
all modulation on this track" is then a flat dump of two small arrays. "What modulates
cutoff" is a filter over `routes` by `target`. "The matrix" a UI wants to draw is a pivot
table over the same two arrays computed on read — never stored as a matrix.

One uniqueness rule must **not** be copied from the precedent it otherwise mirrors:
`AutomationLane` is store-enforced at most one lane per `{target, track}`
(`automation.addLane` is idempotent on a repeat target — a second call returns the existing
lane unchanged). A modulation `target` must allow **many simultaneous routes** — "stack as
many modulators on the same parameter as you want" is the entire feature (§2's Bitwig
citation). `mod.addRoute` always creates a new route; it is never idempotent on a repeat
target the way `automation.addLane` is.

This wins on the AI-addressability test specifically because the action space collapses to
four small, composable verbs (add a source, add a route, set a depth, describe) instead of
either a giant sparse matrix payload or a bespoke drag gesture that has no non-visual
equivalent. It is also **not a new invention** — it is the same shape this codebase already
uses twice (`Effect` on a track, `AutomationLane` on a track), so the store, the control
verbs, and the MCP tools it needs are structurally identical to code that already exists and
is tested.

**Cheap 80% of (d) without a graph**: let a route's `target` be allowed to point at *another
source's own parameter* (e.g., an LFO's `rateHz`) in addition to an effect param — this buys
"LFO2 modulates LFO1's rate" (classic FM-style meta-modulation, and Bitwig's "modulation of
modulation depth" idea) without ever building a node-graph UI or a cycle-aware render
scheduler for arbitrary math nodes. Cycle detection here is cheap because the only edges are
`source → route → target`, exactly the shape `SidechainGraph.cyclePath` already walks for a
structurally identical problem (source track → keyed effect) — reuse that BFS, don't write a
second one.

## 4. Depth, polarity, curve semantics

- **Combination**: additive is the standard and the right default —
  `resolved = clamp(base + Σ(depth_i × routeCurve_i(sourceValue_i)), range)`, evaluated once
  per resolution step (§7 splits what "once per" means) on the same "engine intake" step
  that already resolves tempo-synced delay time and pokes `storeAutomatedParam`.
  Multiplicative combination is occasionally useful for gain-type destinations (avoids
  modulation pushing a fader from -inf to +6dB in one step) but should be an explicit
  per-route flag, not the default — JUCE's `SmoothedValue` documents exactly this split for
  exponential-feeling params like dB/Hz [[JUCE — SmoothedValue]](https://docs.juce.com/master/classSmoothedValue.html).
- **Depth is a fraction of the target's *own* `EffectParamSpec.range`**, matching how
  `AutomationTarget.valueRange` already clamps automation values — no separate depth-unit
  system. A depth of `0.4` on a param never means "40% of 0–1"; it means "40% of that
  param's actual span."
- **Bipolar vs unipolar**: a route needs its own polarity flag independent of the source's
  native polarity — an LFO's raw output is bipolar (-1…1); routing it to a destination that
  should only ever *add* (never subtract) needs a unipolar remap at the route, not a second
  copy of the LFO. Bitwig's Segments envelope literally exposes a `Bipolar` toggle for this
  reason: "rescales it so the minimum value is -1 and the middle value is now 0"
  [[Bitwig user guide — modulator]](https://www.bitwig.com/userguide/latest/modulator/).
- **Modulation of modulation depth**: Bitwig allows a modulator's *rate* to itself be
  modulated ("Both the Rate and Timebase can be modulated for each note, for example by
  Velocity" [[Bitwig user guide]](https://www.bitwig.com/userguide/latest/modulator/)) — this
  is exactly the "route targets another source's param" mechanism from §3's verdict, not a
  separate feature.
- **Per-voice vs global is the single most important semantic distinction to get honest
  about**, and it maps directly onto an architectural boundary that already exists in this
  codebase (see §8): a *track-level* route graph evaluates once per resolution step and
  applies the *same* resolved value to every voice a track's instrument is currently
  sounding — this is "global" modulation (a whole-track LFO on filter cutoff moves every
  held note's filter identically). *Per-voice* modulation (this note's velocity scales its
  own filter envelope differently from the note next to it) is **instrument-internal**
  state, living inside `PolySynthInstrument`'s existing per-`Voice` struct
  (`PolySynthInstrument.swift:61-75`, which already carries `velocityAmp`, `stage`, `level`
  per voice). Promising true per-voice modulation from the track-level route graph would be
  a confident wrong design — the graph has no notion of "which voice" at all.
- **Smoothing/zipper noise**: the codebase's own precedent is `GainEffect.invertPolarity`,
  which "ramps through zero over ~5 ms" rather than jumping (`Effects.swift:989`) —
  reuse that same one-pole/linear ramp shape for the resolved modulation value itself,
  applied once per resolution step, so a destination effect that recomputes coefficients
  directly from its raw param (most of our filters/EQ bands do) never sees a step larger
  than the ramp allows. JUCE's `SmoothedValue` exists to solve exactly this ("the single
  most common beginner bug is changing a gain or coefficient abruptly per block, producing
  audible steps" [[JUCE forum digest]](https://forum.juce.com/t/efficient-parameter-smoothing/16077))
  — same problem, same fix, no new invention needed.

## 5. Macro controls

**A macro is a modulation *source*, not a separate subsystem.** Concretely: a macro is a
named constant-value source (`kind: "macro"`, one param: its own current value, 0…1 or a
custom range) that one `mod.setValue` command drives directly — analogous to `fx.setParam`
but on a source instead of an effect. "One macro drives eight targets, each with its own
range/curve" is then simply **eight ordinary routes from one source**, each carrying its own
depth/curve/polarity, exactly like any LFO's routes. This is deliberately how Ableton's Racks
work under the hood too: eight (now up to sixteen, Live 12) knobs, each mapping is
independently rangeable and invertible — "the first is the Min and Max range on each
mapping... the second is inverting a mapping by setting Min higher than Max"
[[Ableton Forum — macro mapping]](https://forum.ableton.com/viewtopic.php?t=225854).

**Why this matters enormously for AI control**: a macro is a *semantic, named, single-number
handle* over an arbitrary sub-graph of the chain — "Brightness," "Chaos," "Punch" — that
collapses however many underlying parameters into one clean, discoverable dial an agent can
turn with a single `mod.setValue` call, without needing to know or touch the eight things it
actually moves. This is the cheapest, highest-leverage AI-control primitive in this entire
report.

**Snapshots/morphing**: a macro *snapshot* is simply a saved set of source **values** (not
routes) — Ableton's "Macro Variations" are exactly this: "you can capture and recall
instantly the positions of your macro parameters" [[Ableton Help — Macros and Variations
FAQ]](https://help.ableton.com/hc/en-us/articles/360019103480-Macros-and-Variations-FAQ).
Notably, **Ableton itself has no built-in morph/interpolation between variations** — users
resort to third-party Max for Live devices for that
[[Ableton Forum — morphing transitions]](https://forum.ableton.com/viewtopic.php?t=249910).
That's a concrete, verified competitive gap: since a snapshot here is "just a dict of
source-id → value," **linear interpolation between two snapshots is nearly free to implement**
(`lerp` each source value, republish) and would be a small feature that beats Ableton's
shipped behavior outright — worth flagging as a cheap differentiator, not just parity.

## 6. Tempo sync — wire representation

Reuse `NoteDivision` verbatim (`"1/4"`, `"1/8d"`, `"1/8t"`, …) as the wire string for any
synced source's rate, exactly as `DelayEffect`'s `division` param already does on the wire
today. Add the one missing rung the brief calls for:

```swift
case sixtyFourth = "1/64", sixtyFourthDotted = "1/64d", sixtyFourthTriplet = "1/64t"
```

appended to `NoteDivision` (`TempoMap.swift:266`) — additive, no re-encoding, no slot-index
consequence anywhere since `NoteDivision` isn't itself stored at a fixed automation slot (only
its *resolved* numeric value is, per the existing delay precedent).

An LFO source's rate param therefore needs a **mode flag**: `free` (plain `rateHz`, an
ordinary float param) vs `synced` (`division: NoteDivision`, resolved to `periodSamples` at
publish time using the *current* tempo, exactly like `DelayTempoSync`). Both should be legal
`EffectParamSpec`-shaped params on the LFO source kind so `mod.describeKinds` can surface
them uniformly — mirroring how `DelayParams` exposes both `timeMs` and `division` on the same
effect today (`Effects.swift:1128-1149`).

## 7. Two modulation tiers: control-rate vs event-rate (a measured course correction)

This section was added mid-sprint after the coordinator surfaced
`Sources/DAWCore/RenderBlockSize.swift` — a measured constraint the industry sources in the
rest of this report cannot supply, and one that overturns the single-tier "resolve once per
quantum" design §1/§4 describe as *this codebase's existing precedent* without yet
questioning whether that precedent should extend, unmodified, to every modulation source
kind. It should not. Below is an independent read, not an agreement-by-default.

### 7.1 Does a single tier work? No — and the two failure modes are different in kind, not just degree

`RenderBlockSize.swift` and `EffortField.swift` document a *measured* mechanism (not this
report's synthesis): AUSampler reads its MIDI controller inputs once per host render call, so
every pitch-bend/CC lane written to a hosted AU is sample-and-held at the block rate. At the
old 4096-frame offline block (11.719 Hz sampling, 5.86 Hz Nyquist) this did not just blur a
vibrato — it produced **alias images at `|samplingHz − rateHz|`, several louder than the
fundamental**: a commanded 11.72 Hz vibrato came back as "0 ¢ — a static −17.9 ¢ detune," and
an 8 Hz vibrato came back with a 41.7 ¢ image at 3.72 Hz against a 19.2 ¢ fundamental. The fix
(m28-bug) lowered the offline block to 512 frames (93.75 Hz sampling, 46.875 Hz Nyquist),
which clears the entire musical modulation band, and paired it with an honesty predicate,
`EffortField.modulationAliasesUnacceptably`, that warns/suppresses rather than silently
delivering a wrong result — the closed form is
`EffortField.modulationImageRatio(rateHz:samplingHz:)`, a zero-order-hold sinc-weighting
formula "measured at four rates within 3%," not an estimate.

**This mechanism is general zero-order-hold DSP theory, not an AU-specific fact** — it applies
identically to *any* modulation source resolved once per block and held constant across it,
regardless of destination. It transfers directly to this report's own design: §1/§4's "resolve
once per quantum, poke `storeAutomatedParam`" is the *same* sample-and-hold operation on our
own built-in effects that AUSampler's MIDI-read cadence performs on hosted AUs. The measured
evidence therefore applies to Tier A below just as much as it did to the hosted-AU case it was
measured on — with one important difference in our favor: we are not host-constrained the way
an AU host is, so we have latitude AUSampler never had to choose a *different* resolution
cadence for our own modulation layer (§7.3 uses exactly that latitude).

**Smooth/continuous sources (LFO, envelope, envelope follower, macro, smoothed-random) —
Tier A, control-rate is adequate, WITH a guard.** At the shipped 512-frame block (93.75 Hz,
46.875 Hz Nyquist), the measured table in `RenderBlockSize.swift` already shows the entire
practical vibrato/tremolo range delivering cleanly — even 11.72 Hz, the worst case at the old
block, now reads "47.6 ¢ at 11.72 Hz" with no static-detune failure. Ordinary musical LFO
rates (0.05–20 Hz) sit at 0.05%–21% of Nyquist, comfortably inside the region the fix was
built to clear. **But nothing in the proposed wire surface stops an agent from authoring a
60 Hz "audio-adjacent" tremolo**, which would alias exactly as the 11.72 Hz bend case used to.
Tier A therefore needs the *same* honesty mechanism this codebase already ships for the
adjacent problem, generalized — not reinvented (§7.4).

**Rhythmic/edge sources (step sequencer, trance gate) — Tier B, control-rate does NOT work,
independently confirmed.** The coordinator's arithmetic is right, and it is worth stating
*why* precisely rather than just agreeing: resolving a hard step edge once per quantum means
the edge lands wherever in the block the resolution happened to fall relative to the true
musical position — at 93.75 Hz that's a ~10.67 ms grid, which against a 128 BPM sixteenth
(117.2 ms) is ~9% slop. That slop is also **inconsistent** — it is not a fixed, predictable
quantization to a grid (which would at least read as "deliberately swung"); it is a
block-phase-dependent jitter that varies edge to edge depending on exactly where the musical
event falls relative to the arbitrary block boundary. And critically, **this is a different
failure mode from Tier A's, not a smaller version of the same one**: Tier A's problem is
*aliasing* — a wrong frequency component appears, and it can be louder than what was asked
for, reading as "detuned" or "warbling." Tier B's problem is *timing jitter* — nothing is at
the wrong pitch or level, an edge is simply not quite where it should be, reading as "loose"
or "not tight." For a genre convention (trance gates, rhythmic sidechain-style gating) whose
entire appeal is mechanical tightness, a 9% jittery slop is arguably *more* damaging to the
intended effect than Tier A's aliasing is to a vibrato, even though it is a "smaller" number
in milliseconds. **Verdict: the two tiers must be architecturally separated; a single
block-rate design should not be shipped for both.**

### 7.2 How real systems get sample-accurate rhythmic modulation while still running control-rate LFOs — and what we already have to build it from

The industry pattern, confirmed directly rather than assumed: VST3 does not resolve
automation once per block either. `ProcessData` carries `IParameterChanges`, a per-block
queue of `IParamValueQueue`s, each a list of `(sampleOffset, value)` pairs — "sampleOffset
represents how many samples from the beginning of the current block." The plugin is expected
to apply each change *at* its offset, via sub-block splitting or an in-loop consumer, for
sample-accurate automation; VST3's own developer docs are explicit that a plugin using "a
single parameter value inside the processing block... is not sample accurate automation"
[[Steinberg — Understanding parameter updates in VST3]](https://dev.classmethod.jp/en/articles/vst3-plugin-parameter-flow-again-processdata-inputparameterchanges/)
[[VST3 Interfaces — IParamValueQueue]](https://steinbergmedia.github.io/vst3_doc/vstinterfaces/classSteinberg_1_1Vst_1_1IParamValueQueue.html).

**We already have exactly this shape, twice, and neither is a new invention this report is
proposing:**

1. `ScheduledMIDIEvent.sampleTime` (`MIDISchedule.swift:15`) is a per-event, anchor-relative
   sample offset, and `InstrumentSourceNode` already computes a per-quantum *slice* of such
   events bounded by `windowEnd` and hands that slice into a single `render()` call — the
   identical `(offset, value)`-queue shape VST3 formalizes, already load-bearing for
   sample-accurate note-on/off and CC delivery in this engine today.
2. `AutomationSchedule.value(at:points:cursor:)` already takes an arbitrary absolute sample
   time, not just a block-start time (§1) — its breakpoint/cursor math is *already*
   sample-accurate. The only reason effect-param automation is block-rate today is that
   `AutomationRenderer.storeEffectParams` chooses to call it once per quantum.

**Therefore Tier B is not a new data structure — it is a different *consumption* pattern
built from parts that exist.** A step sequencer's edges are ordinary `AutomationBreakpoint`s
with `holdsSegment: true` (a hard step, not a ramp) at their exact sample times, built
off-render-thread against `TempoMap` exactly like every other tempo-synced value in this
codebase (§1, §6). What's new is the consumer: a Tier-B-capable effect's
`process(buffers:frameCount:)` must accept a small in-block `(offset, value)` slice for that
quantum — mirroring `InstrumentSourceNode`'s existing `slice`/`cursor`/`windowEnd` shape —
and its own inner loop must be able to restart at an arbitrary sub-block offset, applying the
new value before continuing, rather than reading one value for the whole call. This is real,
non-trivial, **per-effect** engineering: a plain multiply (`GainEffect`) can do this almost
for free (split the buffer, multiply each sub-range by its own scalar); a biquad-coefficient
effect (EQ) needs materially more care (a coefficient recompute at a sub-block boundary is a
much larger perturbation than a gain step). This should be scoped as its own milestone line,
per-effect, not assumed to fall out of the source/route data model in §3 for free.

### 7.3 Live vs offline divergence — the honest state of the art here, and the correct target

State plainly what this codebase's *adjacent* fix currently does, because it is instructive
about what NOT to repeat for the new layer: it does not architecturally decouple live from
offline. It **measured** that on one development rig, the live HAL buffer happens to be 512
frames, lowered the offline block to match, and shipped that equality — while its own doc
comment is explicit that this is contingent: "that equality is a fact about THIS machine's
HAL buffer, not a guarantee... the HAL buffer size is a device setting a user can change."
Before that fix, the divergence was measured directly: "live was 8× finer than the bounce...
the same project, monitored and then bounced, delivered vibrato at two different RATES, and
the one the user approved was not the one written to disk." That is an honest, working fix
for the problem it targets, and it is also fragile by its own account — a different Mac, a
different audio interface, or a user changing their output buffer size in Audio MIDI Setup
can reopen the identical divergence for live monitoring (offline bounces are unaffected;
they always pull at `RenderBlockSize.offlineFrames` regardless of hardware).

**The direct answer to "is the standard answer to decouple, or to interpolate": decouple.**
For *our own* modulation engine — unlike the AUSampler case, we are not constrained by a
third-party plugin's internal read cadence — the architecturally correct target is a **fixed
control rate, independent of whatever block size the engine happens to be called with**,
exactly SuperCollider's long-standing model: control-rate unit generators compute one value
per fixed-size control period (64 samples by default) regardless of the audio block size
around them [[SuperCollider — K2A / control-rate]](https://doc.sccode.org/Classes/K2A.html).
Concretely: within one render callback of `frameCount` samples (512 offline today; 128, 256,
or 1024 depending on rig live), loop in fixed control-period sub-chunks
(`min(controlPeriod, frameCount − offset)`) and resolve/sum/smooth modulation once per
sub-chunk rather than once per whole quantum. Live and offline then sound identical **by
construction** — both resolve at the same fixed Hz — rather than by the coincidence of two
independently-chosen block sizes matching on one rig, closing exactly the fragility
`RenderBlockSize.swift` already flags in its own comments.

**Cost is unmeasured here and must be benchmarked before a specific period is chosen** — this
report will not repeat the mistake the codebase's own lore warns against elsewhere
(estimating rather than measuring). The precedent for *how* to decide is m28-bug itself: it
did not assume 512 was affordable, it measured "8 hosted sound-bank tracks, 120 s... 4096 →
0.449 s, 512 → 0.587 s. A 1.31× bounce, 204× realtime instead of 267×. Paid." A fixed
64-sample control period is a further ~8× finer than the current 512-frame block; expect a
further real cost, unknown multiplier, and measure it the same way before committing.

**Decoupling shrinks Tier A's problem to near-irrelevance but does not touch Tier B's — they
remain different problems even after this fix.** At a fixed 64-sample control period
(750 Hz, 375 Hz Nyquist at 48 kHz), essentially every musically sensible LFO rate — including
fast "audio-adjacent" ones up to ~150 Hz with real margin — sits safely below Nyquist, and
§7.4's warning mechanism becomes a defensive backstop for pathological rates rather than a
wall most authored music would ever hit. But no periodic control rate makes a *hard edge*
land exactly on an arbitrary musical position, short of either (a) a control period small
enough to defeat the entire point of having one, or (b) explicit sample-accurate event
scheduling. **A smaller, fixed control rate is the correct fix for Tier A's aliasing; Tier B
still needs §7.2's event-queue mechanism regardless of how small the control period gets** —
a continuous signal's frequency content and a discrete event's timing precision are different
problems and need different mechanisms.

### 7.4 The "warn honestly" vocabulary already exists — reuse it, don't re-derive it

The coordinator is right that this is an available design option, and it should be used
literally rather than approximated: `EffortField.modulationImageRatio(rateHz:samplingHz:)` is
a destination-agnostic closed form (zero-order-hold sinc weighting, measured to within 3%),
and `EffortField.modulationAliasesUnacceptably`/`bendVibratoWarning` are the pattern for
turning that ratio into a named, actionable, `warnings`-array-shaped sentence rather than a
silent bad result. The new modulation layer's Tier A sources should get a sibling predicate
— computed against whichever control rate the layer actually resolves at (§7.3's fixed
period once it exists; `RenderBlockSize.modulationSamplingHz()` as an honestly-weaker interim
if Tier A ships before the control-rate decoupling does) — returning a
`mod.addSource`/`mod.setSourceParam` response `warnings` entry the same shape `fx.setParam`
already uses for clamps (m27-c), naming the requested rate, the sampling rate, and the image
ratio, exactly as `bendVibratoWarning`'s prose already does for the adjacent problem.

## 8. RT-safety notes

1. **Preallocate two small fixed-capacity arrays per track**: modulation sources (suggest a
   cap of 16/track — generous for any real session) and routes (suggest 64/track, matching
   the existing `AutomationSchedule.maxEffectParamTracks = 64` precedent exactly). Publish
   both through the **same `daw_atomic_ptr` + monotonic `generation` + ≥1 s main-actor retire
   bin** pattern `PolySynthInstrument` already runs in production — this is not a new RT
   mechanism, it's the third user of an existing one (the first two being
   `PolySynthInstrument`'s param snapshot and `AutomationRenderer`'s schedule pointer).
2. **Separate cold graph state from hot render state, explicitly.** The route
   list/source-definition list is *cold*: edited rarely, main-actor side, republished on
   every add/remove/depth-change. But an LFO's phase accumulator, an envelope follower's
   RMS/peak state, a step sequencer's current step index, a random source's current
   hold-value — these are *hot*, mutable every resolution step, and **must be keyed by the
   source's stable UUID into a fixed render-side slot table that survives a cold-graph
   republish.** Get this wrong and every unrelated route edit resets every LFO's phase — not
   a cosmetic bug, an audible glitch on every automation-adjacent action.
3. **Resolve Tier A at a fixed control rate, not the outer render block; resolve Tier B via
   sample-accurate events, not a per-block poke — §7 is the load-bearing section for this
   item,** superseding a naive reading of the `storeAutomatedParam` precedent in §1. Tier A
   sources advance their phase/state once per control period (§7.3); Tier B sources publish
   exact-sample-time hard-step breakpoints consumed by a per-effect sub-block loop (§7.2).
   Both fold into the same additive-offset-on-top-of-the-automation-base-value model from §4
   — modulation is an offset on the value already reaching each effect, not a parallel
   pipeline, regardless of which tier resolved it.
4. **Tempo math never runs on the render thread**, full stop — same rule `DelayEffect`
   already enforces. A synced LFO's `periodSamples` (or a step sequencer's per-step sample
   times) is computed main-actor-side against `TempoMap` whenever tempo *or* division changes
   and republished with a fresh `generation`; the render thread does one accumulator add (Tier
   A) or one sorted-event walk (Tier B) per resolution step, nothing else.
   *(Open question for whoever implements this: confirm the exact call site that currently
   re-triggers `DelayTempoSync` on a tempo-map edit mid-playback, and hang the LFO/step
   republish off the same hook — this report did not verify that site and should not be read
   as having done so.)*
5. **Smoothing** lives at the same intake step as the summation in §4 — a short (5–20 ms)
   one-pole ramp on the *resolved* value, state also keyed by route ID in the hot slot table,
   directly reusing the shape of the `invertPolarity` 5 ms ramp-through-zero that already
   ships. This is a Tier A concern specifically; Tier B's hard steps are hard steps by design
   (a smoothed trance-gate edge is a contradiction) and should not be ramped by default.
6. **Audio-rate modulation (FM/RM, per-sample LFO) is explicitly out of scope** for this
   track-level layer, and is now explicitly a *third* tier beyond §7's two — it cannot be
   control-rate or event-rate under this design without a genuinely different, per-sample
   path. Flag as a possible future instrument-internal-only capability, not a v1 deliverable.
7. **Envelope-follower sources reuse `SidechainGraph` outright**: its cross-track key tap,
   its cycle detection (`cyclePath`), and its existing limits (key **sources** must be
   non-bus tracks; key **destinations** need a `ChainHostAU` insert point, so instrument
   strips can't be keyed directly today) all carry over unchanged. Do not build a second
   routing-validity graph. Its PDC consequence should be surfaced the same way, too: the
   `fx.setSidechain` response already carries `sidechainSkewSamples`
   (`Commands.swift:2526-2531`) — an envelope-follower source's entry in `mod.describe`
   should carry the identical field, not a silently-different or missing one.
8. **Master-strip scope should match automation's shipped restriction until deliberately
   extended together.** `addMasterAutomationLane` accepts only `{type:"volume"}` today
   (`masterAutomationVolumeOnly` for anything else, `Commands.swift:3162-3164`) even though
   `fx.setParam` on `trackId:"master"` already reaches master-chain effect params directly.
   `mod.addRoute` on `trackId:"master"` should refuse any target but volume for the same
   reason — not silently allow master effect-param modulation ahead of automation itself
   supporting it.
9. **A param with active modulation routes should say so when its base value is set.** When
   `fx.setParam` targets a param that also carries one or more active routes, the response's
   `warnings` array should name them — the same teaching `track.setVolume` already gives when
   an automation lane, not the caller's argument, governs the rendered value
   (`activeLane(for:)`, moved to `DAWCore` specifically so the control plane could give this
   answer, `Automation.swift:416-423`). Otherwise an agent that calls `fx.setParam` on a
   modulated cutoff and hears it keep moving has no way to learn why from the response alone.

## 9. Product study — summary table

| Product | Routing model | Macro/composite control | Tempo sync | What's notable / what users hit |
|---|---|---|---|---|
| **Ableton Live 12** | Per-device breakpoint/LFO M4L modulators mapped onto Live's generic device-parameter mapping system (not a unified matrix) | Racks: 8 macros default, up to 16; per-mapping min/max + invert; "Macro Variations" = value snapshots | Yes, on LFO/Shaper rate | `LFO`, `Shaper`, `Envelope Follower` are **Max for Live** devices, not core Live — gated behind Suite/M4L, an addressability trap if we ever mirror "core vs. add-on" gating [[Ableton — Max for Live Devices]](https://www.ableton.com/en/manual/max-for-live-devices/). No built-in macro morph [[Ableton Forum]](https://forum.ableton.com/viewtopic.php?t=249910). |
| **Bitwig Studio** | **"Modulate anything"** — any parameter accepts a stacked list of modulators, each shown as a colored ring [[Dubspot]](https://blog.dubspot.com/bitwig-studio-dubspot-first-look) | `Macro`/`Macro-4` modulator devices; modulation-of-modulation supported (rate modulated by velocity) [[Bitwig user guide]](https://www.bitwig.com/userguide/latest/modulator/) | Yes throughout; `Steps` modulator syncs to transport/groove | Widely regarded best-in-class; **The Grid** is the (d)-style full modular option layered *on top of*, not instead of, the per-parameter model — validates the "(c) base + (d) optional escape hatch" verdict in §3. |
| **Serum / Vital** | Per-parameter drag-and-drop **and** a literal matrix panel over the same list [[digest]](https://s3.amazonaws.com/decembercymatics/Serum_Manual.pdf) | Macro knobs (4, typically) | Yes | The two-views-one-list shape is the direct precedent for this report's §3 verdict. |
| **Kilohearts Phase Plant** | Generators / Modulators / Effects panes; modulators connect to utilities (combine/scale/multiply) in "an infinite number of combinations" — full modular | No dedicated macro layer surfaced in docs reviewed | Yes | Audio-rate FM/RM *between generators* explicitly called out — confirms §2's "audio-rate is a different mechanism" line [[Kilohearts]](https://rekkerd.org/kilohearts-announces-phase-plant-hybrid-modular-synth-with-snapin-integration/). |
| **Native Instruments Reaktor** | Fully modular since 1996 ("Generator") [[NI blog — 25 years]](https://blog.native-instruments.com/25-years-reaktor/) | N/A (build-your-own) | User-built | The historical proof that (d) works, but at the cost of "build your own instrument" — not a v1 shape for a DAW's built-in effects. |
| **FabFilter (Saturn/Timeless/Volcano/Twin/Pro-Q)** | Per-plugin `XLFO` objects, added via `+ New XLFO`, dragged onto any param; XY controller + MIDI Learn on top | XY controller is a 2-D macro (two params, one drag) | Yes (XLFO) | Clean, minimal per-parameter model; confirms drag-and-drop's popularity outside synths too [[FabFilter — XLFO]](https://www.fabfilter.com/help/timeless/using/xlfo). |
| **Cableguys ShaperBox** | Per-Shaper breakpoint curve editor drives that Shaper's own parameter (Volume, Filter, Pan, Crush, etc.) | N/A | Yes | The curve *editor UX* (draw-a-shape) is the interesting differentiator, not the routing model — it's effectively a bespoke MSEG per effect, with an external-sidechain overlay view for visually matching a ducking curve to a kick [[SOS — ShaperBox 3]](https://www.soundonsound.com/reviews/cableguys-shaperbox-3). |

## 10. Gap table

Every row answers the mandatory question: **how would an LLM drive this — PARAM, MODULATOR,
or PRESET?**
- **PARAM** = a plain `fx.setParam`/`track.set*` call, no new subsystem needed.
- **MODULATOR** = needs a `mod.*` source+route (this report's proposed layer).
- **PRESET** = a canned recipe (a specific source+route combination, or a dedicated DSP
  effect) an agent invokes by name, not by composing primitives.

| Capability | Known for it | Musical payoff | Complexity | LLM drives via |
|---|---|---|---|---|
| Tremolo (LFO→gain, e.g. a Gain insert's `gainLinear`) | Every synth ever | Low–medium, ubiquitous | Low — Tier A (§7) | MODULATOR |
| Autopan (LFO→pan) | Every synth ever | Low–medium | Blocked on the mixer-node intake, §12/takeaway 10 — pan is not an `effectParam` | MODULATOR (once the second intake exists) |
| Filter wobble / dubstep bass (synced LFO→cutoff) | Massive, Serum | High (genre-defining) | Low — Tier A, once a resonant filter effect exists (see §11) | MODULATOR |
| Sidechain pump/duck (env follower→gain) | Ableton `Envelope Follower`, analog ducking chains | High (the single most requested "modern" effect) | Medium — Tier A, reuses `SidechainGraph` | MODULATOR |
| Trance gate / rhythmic gating (step seq→gain) | Trance/EDM genre convention | Medium–high | **Medium-high — Tier B (§7.1/§7.2), not a block-rate poke: needs a source built from sample-accurate hard-step breakpoints AND a destination effect whose `process()` can consume a sub-block event queue.** | MODULATOR, but a structurally different verb path from other rows (§12) |
| Vibrato (LFO→pitch) | Every synth | Medium | Low — Tier A, **but** PolySynth has no pitch/detune `EffectParamSpec`-style param today — needs one added first | MODULATOR (once pitch is a target) |
| 8-macro "one knob does the thing" chains | Ableton Racks, Vital | Very high for AI control specifically (§5) | Low (macro = source; N routes) | MODULATOR (macro source) or PRESET (a curated macro pack) |
| Macro snapshot morph | *nobody ships this well* (Ableton has snapshots, no morph — §5) | Medium, but a clean competitive edge | Low (lerp source values) | PRESET (two snapshot IDs + a blend %) |
| Auto-wah / resonant filter sweep | Classic funk/electronic effect | High | Needs a **new** resonant filter insert effect (our EQ bands are peaking, not lowpass; PolySynth already has the exact SVF DSP needed — see §11) | MODULATOR, Tier A, once the effect exists |
| Beat repeat / stutter | Ableton Beat Repeat, glitch plugins (Faultline etc.) | High, distinctly a DJ/loop-domain effect | **Dedicated DSP** — capture buffer + repeat read-head + slice quantize; modulation can only drive *its* params once it exists | PRESET (the effect itself), MODULATOR for its exposed params |
| Granular freeze | Granular/texture plugins | High, distinctly a DJ/loop-domain effect | **Dedicated DSP** — grain buffer + overlapping-grain scheduler | PRESET, MODULATOR for grain-size/density once it exists |
| Tape stop/start | DJ mixers, Glitch 2, Serato-style FX | High, DJ-domain | **Split**: the ramp *shape* is a one-shot envelope (subsumed, §11); the click-free varispeed read head under it is dedicated DSP | MODULATOR for the shape (needs `mod.trigger`, §12), PRESET for the effect |
| Chorus/flanger internal modulation | Every chorus ever | N/A — already shipped | Stays inside `ChorusEffect` — its `rateHz`/`depthMs` are its *own* internal LFO already (`Effects.swift:1178-1186`); re-routing a track-level LFO onto its short delay-line read position would need audio-rate smoothness neither tier in §7 gives it | PARAM (already automatable as-is) |
| Envelope-follower-driven anything-but-gain (e.g. kick-triggered reverb send, kick-triggered filter open) | Bitwig, Bitwig's whole pitch | Medium–high, very "AI can just try things" | Low once the envelope-follower source exists — Tier A, it's a route, same as any other | MODULATOR |
| MPE per-note expression (glide/slide/press/lift) | ROLI, Bitwig, MPE-native synths | High for expressive input, low relevance to a mostly-programmatic/AI-driven DAW | High — needs per-note MIDI channel routing PolySynth doesn't have | Not this layer — instrument-internal, own report if pursued |

## 11. What the modulation layer subsumes — honest yes/no

**Subsumed outright (becomes a recipe of source + route, zero new DSP)**:
tremolo, sidechain pump/duck as a *generic* effect (distinct from and complementary to the
existing compressor-based sidechain — this gives a cleaner, more controllable ducking path
that doesn't need a compressor's knee/ratio math at all), vibrato (once pitch is a target),
any "LFO/env-follower onto an existing effect's already-automatable param" combination (e.g.
reverb send level pumping, delay feedback wobbling, bit-crusher bit-depth stepping) — all
Tier A. **Autopan is a near-miss**: musically identical to tremolo, but pan is not an
`effectParam` — it needs the second, mixer-node intake flagged in §12/takeaway 10, so file it
as "subsumed once that intake exists," not "subsumed today." **Trance-gate/rhythmic gating is
subsumed only once Tier B (§7.1/§7.2) exists** — it is not a Tier A recipe the way tremolo is,
despite looking superficially similar (both are "an oscillator times gain").

**Needs one new piece of DSP first, then is fully subsumed**: auto-wah / resonant filter
sweep. Concretely — `PolySynthInstrument` already contains a correct, cheap, production 2-pole
State-Variable low-pass filter ("Simper TPT form; shared coefficients, per-voice state",
`PolySynthInstrument.swift:17-19`). Extracting that exact filter math into a standalone
**Filter** insert effect (with cutoff + resonance as `EffectParamSpec`s) is a small,
self-contained addition — and the moment it exists, the modulation layer turns it into
auto-wah, filter-LFO wobble, envelope-triggered filter opens, and dubstep-style tempo-synced
wobble bass *for free*, no additional DSP work (all Tier A). This is the single
highest-leverage "effect + modulation layer = new capability" pairing found in this research.
(§12's worked `addRoute` example deliberately targets an EQ param that exists *today* rather
than this not-yet-built `Filter` effect, to keep the wire sketch honest about what's real
now.)

**NOT subsumed — confirmed, matches the brief's suspicion**:
- **Beat repeat / stutter**: needs a capture buffer, a repeat read-head, and slice-boundary
  quantization logic. A modulation layer can drive *its* exposed parameters (repeat
  probability, slice length, gate) once it exists, but cannot BE the effect.
- **Granular freeze**: needs a grain buffer and an overlapping-grain scheduler
  (windowing, grain-density, grain-size, position jitter) — categorically different from a
  parameter-modulation problem.
- **Tape stop/start**: **split verdict**. The characteristic pitch-down ramp *shape* is
  exactly a one-shot envelope (an AHD or custom-drawn curve from 1.0 → 0 playback rate),
  fired by the new `mod.trigger` verb (§12) — that half is fully subsumed by the modulation
  layer's envelope-generator source (Tier A, since the shape itself is smooth/continuous).
  But the thing that curve drives — a click-free, resampling varispeed read head over a
  buffer — is dedicated DSP that has to exist independently and expose "playback rate" as the
  modulation target. Recommend the sibling DJ-effects report scope tape-stop as "one small
  varispeed resampler effect + an envelope-shape modulation route," not as one monolithic
  effect.
- **Reverse / scratch-style buffer manipulation**: dedicated buffer/read-head DSP, same
  reasoning as beat repeat.

This is the exact split to hand the DJ/loop-effects sibling report: **level/filter/send/pitch
-style parameter effects are "free" once Tier A ships (pan pending the mixer-node intake,
trance-gate pending Tier B); anything that reads audio out of order or out of a captured
buffer needs its own DSP regardless of what the modulation layer looks like.**

## 12. Proposed wire surface (`mod.*`)

Follows the `fx.*`/`automation.*` conventions found in `Commands.swift` exactly:
`rejectUnknownKeys`, a `trackId` that accepts a track UUID or the `"master"` sentinel via the
existing `parseFXTarget()` path, named `LocalizedError`-style errors, and a `warnings` array
on any silent clamp (the m27-c precedent). Destinations reuse `AutomationTarget`'s existing
wire shape verbatim — no new target encoding.

**v1 scope, stated plainly**: this wire sketch covers **Tier A only** (§7) — LFO, envelope,
envelope follower, macro, smoothed-random. Step sequencer/Tier B needs the event-queue
consumption mechanism designed in §7.2 built into at least one destination effect before its
own wire shape is worth finalizing; sketching its JSON now would invite the exact
"documented-but-dead" failure this codebase's own delay `sync`/`division` precedent (§1) was
built to avoid. Routing `target`s are **`effectParam` only**, mirroring exactly what
automation ships today at the intake this report actually designed against (§1, §8.3).
`sendLevel` is not proposed as a target — it's v0-rejected by the automation store itself
(`AutomationTarget.valueRange`), so listing it here would overpromise. `volume` and `pan` are
*not* v1 targets either, because they reach the render thread through the mixer node's
`volumePoints`/`panPoints` path, not `storeAutomatedParam` — a second RT intake this report
did not design (takeaway 10). Master-strip routes are restricted to a `volume` target once
that intake exists, mirroring `masterAutomationVolumeOnly` (§8.8) — until then, master
supports no modulation routes at all.

```jsonc
// Add a free-running or tempo-synced LFO source on a track.
// -> mod.addSource
{"trackId": "‹uuid›", "kind": "lfo",
 "params": {"shape": 0, "sync": "synced", "division": "1/8",
            "phase": 0, "unipolar": false, "fadeInBeats": 0}}
// `shape` is numeric-coded (0 sine · 1 triangle · 2 saw · 3 square · 4 sample-and-hold ·
// 5 smoothed-random · 6 custom-drawn), taught via `note` in mod.describeKinds — the SAME
// "numeric surface hides extra semantics" idiom EffectParamSpec's own doc comment already
// names (Effects.swift:935-937), not a bespoke string enum invented for this report.
// <- {"source": {"id": "‹uuid›", "kind": "lfo", "params": {...}}}
// An authored rateHz (or a synced division resolved to an effective rate) that would alias
// unacceptably at the layer's current resolution cadence (§7.4) comes back with a
// `warnings` entry naming the rate, the sampling rate, and the image ratio — reusing
// EffortField.modulationImageRatio's closed form, not a re-derivation.

// Route that source onto the EQ's first peak band frequency, depth 40% of its range.
// (Deliberately an EQ param that exists TODAY, not the not-yet-built "Filter" effect
// from §11/takeaway 3 — this sketch describes only what could ship without new DSP.)
// -> mod.addRoute
{"trackId": "‹uuid›", "sourceId": "‹uuid›",
 "target": {"type": "effectParam", "effectId": "‹uuid›", "param": "peak1Freq"},
 "depth": 0.4, "polarity": "bipolar", "curve": "linear"}
// <- {"route": {"id": "‹uuid›", "sourceId": "...", "target": {...}, "depth": 0.4}}
// UNLIKE automation.addLane (store-enforced at most one lane per target, idempotent on a
// repeat call), a target may carry MANY simultaneous routes (§3) — mod.addRoute always
// creates a new route.

// -> mod.setRouteDepth
{"trackId": "‹uuid›", "routeId": "‹uuid›", "depth": -0.25}

// -> mod.setValue   (drives a macro source directly — the "one knob" AI handle)
{"trackId": "‹uuid›", "sourceId": "‹uuid›", "value": 0.72}

// One-shot envelope sources (the tape-stop-ramp case, §11) need an explicit fire — there
// is no "note-on" for a track-level source to observe.
// -> mod.trigger
{"trackId": "‹uuid›", "sourceId": "‹uuid›"}
// Key-retrigger (an LFO/envelope that restarts on every note-on) is explicitly NOT v1
// scope: it requires the source's hot render state to observe note-on events inside the
// INSTRUMENT node's render context, which the track-level route graph (§8.2) has no
// visibility into. Flagged here, not designed.

// -> mod.removeSource / mod.removeRoute
{"trackId": "‹uuid›", "sourceId": "‹uuid›"}
{"trackId": "‹uuid›", "routeId": "‹uuid›"}

// -> mod.describe   ("describe all modulation on this track")
{"trackId": "‹uuid›"}
// <- {"sources": [
//       {"id", "kind": "lfo", "params": {...}},
//       {"id", "kind": "envelopeFollower", "params": {"sourceTrackId": "...", ...},
//        "sidechainSkewSamples": 32}    // same PDC-skew honesty fx.setSidechain reports
//     ],
//     "routes": [{"id", "sourceId", "target", "depth", "polarity", "curve",
//                 "effectiveRange": {"min": 300, "max": 900, "unit": "Hz"}}]}
//    effectiveRange is computed from the target's CURRENT base value ± depth·range, in
//    the target's own display units — e.g. "depth 0.4 on peak1Freq, base 500 Hz -> 300
//    Hz…900 Hz" — the field an agent actually needs to judge whether a route is audible.

// -> mod.describeKinds   (schema discovery — the fx.describe precedent, SAME field
// names {name, min, max, default, unit, note?}, Commands.swift:2537)
{}
// <- {"kinds": [
//      {"kind": "lfo", "params": [
//        {"name": "rateHz", "min": 0.01, "max": 20, "default": 1, "unit": "Hz",
//         "note": "rates that would alias at the layer's current resolution cadence are "
//                 + "warned, not silently delivered — see mod.addSource"},
//        {"name": "shape", "min": 0, "max": 6, "default": 0, "unit": "enum",
//         "note": "0 sine · 1 triangle · 2 saw · 3 square · 4 sample-and-hold · "
//                 + "5 smoothed-random · 6 custom-drawn"},
//        {"name": "depth", "min": -1, "max": 1, "default": 1, "unit": "linear"} ],
//       "targets": ["effectParam"]},
//      {"kind": "envelopeFollower", "params": [
//        {"name": "attackMs", "min": 1, "max": 500, "default": 10, "unit": "ms"},
//        {"name": "releaseMs", "min": 5, "max": 2000, "default": 200, "unit": "ms"},
//        {"name": "sourceTrackId", "min": 0, "max": 0, "default": 0, "unit": "trackId",
//         "note": "not a numeric quantity — a track-id string, the same non-numeric-"
//                 + "field precedent as DelayEffect's sync/division string fields "
//                 + "living outside strict EffectParamSpec numeric semantics. Reuses "
//                 + "SidechainGraph — same source/destination limits as fx.setSidechain; "
//                 + "the source's mod.describe entry carries sidechainSkewSamples."} ]},
//      {"kind": "macro", "params": [{"name": "value", "min": 0, "max": 1, "default": 0,
//         "unit": "linear"}]},
//      ... ]}
```

**Errors** should mirror the existing named-error style: `modSourceNotFound`,
`modRouteNotFound`, `modTargetUnresolvable` (unknown effect/param — same shape as
`automationTargetUnresolvable`), `modSourceCycle` (reusing `SidechainGraph`-style cycle
naming when a route targets another source's own param and closes a loop),
`sidechainWouldCreateCycle` reused verbatim for envelope-follower sources (literally
delegate to `SidechainGraph.cyclePath`), and `modMasterVolumeOnly` mirroring
`masterAutomationVolumeOnly` (§8.8) for any non-volume route requested on `trackId:"master"`.

## 13. Actionable takeaways

1. **ROADMAP: add a "Modulation layer" milestone**, scoped exactly as §3's verdict: source
   objects + route objects per track, `mod.*` control verbs, MCP tools, and a headless test
   suite mirroring the existing `automation.*` test shape. Route: `daw-architect` for the
   data-model/RT design (it touches the render thread and needs the same review rigor as any
   RT-safety change), then `mcp-integration-engineer` for the wire/MCP plumbing once the
   architecture is approved.
2. **Ship the LFO source first, envelope follower second, step sequencer and macro third.**
   LFO alone (§10's top rows) unlocks tremolo/wobble/vibrato — the highest payoff-to-complexity
   ratio in the gap table. Envelope follower is the second-highest payoff (generic sidechain
   pumping) and the cheapest to build correctly because `SidechainGraph` already exists.
   Step sequencer is now explicitly Tier B (§7) — schedule it AFTER at least one destination
   effect has the sub-block event-consumption capability §7.2 describes, not alongside the
   Tier A sources.
3. **ARCHITECTURE: extract `PolySynthInstrument`'s SVF low-pass into a standalone `Filter`
   insert effect** (cutoff + resonance as ordinary `EffectParamSpec`s). This is the one
   concrete missing piece of DSP that turns the modulation layer into auto-wah and
   wobble-bass "for free" (§11) — flag as a small, self-contained item a sibling
   `audio-dsp-engineer` task could do independently of the modulation-layer milestone itself.
4. **`EffectParamSpec` needs one additive field**: a `scale` hint (`"linear"` / `"log"`,
   defaulting to `"linear"` so nothing existing changes) so modulation depth (and manual
   knob curves generally) behave musically on Hz/dB-range params instead of sweeping mostly
   one octave of a cutoff's range. Append it the same way `note` was appended — never
   reorder, never touch existing slot indices.
5. **`NoteDivision` needs a `1/64` rung** (`sixtyFourth`/`...Dotted`/`...Triplet`), appended
   to the existing enum — required for the tempo-sync section of the brief and for any
   synced LFO/step-sequencer source to reach the fast end of the practical range.
6. **Hand the DJ/loop-effects sibling report §11's split verbatim**: level/filter/send
   modulation-style effects (tremolo, wobble, pump, the tape-stop *ramp*) are free once Tier A
   ships (autopan pending takeaway 10, trance-gate pending Tier B/§7.2); beat repeat,
   granular freeze, reverse, and the tape-stop *varispeed read head* are dedicated-DSP items
   regardless of the modulation layer's shape.
7. **MCP layer**: compose the two-call `mod.addSource` + `mod.addRoute` pattern into
   higher-level, single-shot agent-facing tools (e.g. `add_lfo_modulation`,
   `add_sidechain_duck`) the way the MCP server likely already composes other multi-call
   control-protocol sequences into single semantic tools — keeps the wire protocol minimal
   and composable while keeping the AI-facing surface a one-call action for the common cases.
8. **Do not promise per-voice modulation from the track-level route graph** in any user- or
   agent-facing copy — it is global/monophonic by construction (§4, §8.2). Per-note/MPE-style
   expression is a distinct, larger, instrument-internal effort and deserves its own
   scoping pass if pursued, not a bullet in this milestone.
9. **Open question for the implementer, not resolved here**: the exact call site that
   currently republishes `DelayTempoSync`'s resolved `timeMs` when the tempo map changes
   mid-playback. A synced LFO/step-sequencer source must hang off the identical hook; this
   report located the *principle* (`DelayEffect.storeAutomatedParam`'s comment) but did not
   trace the live call site, and it should not be read as having verified one.
10. **A second RT intake is required before volume/pan modulation (and therefore true
    autopan) can ship**: this report's RT design (§8) is grounded entirely in the
    effect-param `storeAutomatedParam` path; volume/pan automation reaches the render thread
    through the mixer node's `volumePoints`/`panPoints` cursor evaluation instead (§1). v1
    should ship `effectParam`-only targets (§12) and scope a mixer-node modulation intake as
    a distinct, separately-reviewed follow-up rather than assume it falls out for free.
11. **`fx.setParam` (and any future `track.set*`) should warn when the target also carries
    active modulation routes**, naming them in the response — mirrors the existing
    `activeLane`/`track.setVolume` teaching (§8.9) and prevents an agent from being confused
    when a value it just set keeps moving.
12. **ROADMAP: split the modulation-layer milestone into Tier A and Tier B work items
    explicitly, not one undifferentiated "modulation" line** — §7 independently confirmed the
    coordinator's suspicion that a single block-rate design cannot serve both smooth
    modulators and rhythmic gate edges, and named *why* the two failure modes (aliasing vs.
    timing jitter) are different in kind, not degree. Tier A (LFO/envelope/follower/macro) is
    the v1 deliverable in items 1–2 above; Tier B (step sequencer/trance gate) is gated on
    §7.2's per-effect sub-block event consumption and should be tracked as its own,
    later-scoped item.
13. **Reuse `EffortField.modulationImageRatio` and the `modulationAliasesUnacceptably`/
    `bendVibratoWarning` pattern for the new layer's Tier A sources, generalized beyond
    hosted-AU controller lanes** (§7.4) — the closed form is destination-agnostic
    zero-order-hold theory, already implemented and measured to within 3%; do not re-derive
    it. An agent authoring an aliasing-prone rate should get the same named, actionable
    warning this codebase already ships for the adjacent bend-lane problem.
14. **Scope "decouple control rate from the render block size" (a fixed control period,
    SuperCollider-style, e.g. 64 or 128 samples, §7.3) as its own, MEASURE-FIRST milestone
    item** — it is the architecturally correct fix for the live/offline divergence risk this
    report identified (today's fix for the adjacent AU problem is a measured coincidence on
    one development rig, and `RenderBlockSize.swift`'s own comments flag that as fragile),
    but its cost is unmeasured here. Benchmark it the way m28-bug benchmarked 512 (a real
    render, a real timing, a real percentage) before committing to a specific period —
    do not assume the cost is affordable by analogy.
15. **Every Tier-B-capable destination effect needs its own sub-block-consumption work**
    (§7.2) — `GainEffect` is the cheap case (a scalar multiply split at an offset is nearly
    free); coefficient-based effects (EQ, a future resonant `Filter`) are not, and each
    should be scoped and reviewed per-effect by `audio-dsp-engineer`, not bundled silently
    into the Tier A modulation-layer milestone.

## Sources

- [Ableton — Max for Live Devices (LFO, Shaper, Envelope Follower)](https://www.ableton.com/en/manual/max-for-live-devices/)
- [Ableton Forum — macro mapping, min/max range, invert](https://forum.ableton.com/viewtopic.php?t=225854)
- [Ableton Help — Macros and Variations FAQ](https://help.ableton.com/hc/en-us/articles/360019103480-Macros-and-Variations-FAQ)
- [Ableton Forum — no built-in macro-variation morphing](https://forum.ableton.com/viewtopic.php?t=249910)
- [Ableton Forum — up to 16 macros in Live 12](https://forum.ableton.com/viewtopic.php?t=241950)
- [Bitwig Studio user guide — Modulator](https://www.bitwig.com/userguide/latest/modulator/)
- [Dubspot — Bitwig Studio in 2026 ("modulate anything")](https://blog.dubspot.com/bitwig-studio-dubspot-first-look)
- [Polarity Music — Bitwig Steps modulator guide](https://polarity.me/posts/bitwig-guides/2022-08-08-steps-bitwig-modulator-guide/)
- [Polarity Music — Bitwig Random modulator](https://polarity.me/topics/random-modulator/)
- [Xfer Serum manual (PDF)](https://s3.amazonaws.com/decembercymatics/Serum_Manual.pdf)
- [The Producer School — Serum 2 vs Vital](https://theproducerschool.com/blogs/music-production/serum-2-vs-vital-the-ultimate-wavetable-synth-comparison-2025)
- [Kilohearts / rekkerd.org — Phase Plant hybrid modular synth](https://rekkerd.org/kilohearts-announces-phase-plant-hybrid-modular-synth-with-snapin-integration/)
- [Kilohearts — Phase Plant product page](https://kilohearts.com/products/phase_plant)
- [Native Instruments blog — 25 years of Reaktor](https://blog.native-instruments.com/25-years-reaktor/)
- [FabFilter Timeless 3 Help — XLFO](https://www.fabfilter.com/help/timeless/using/xlfo)
- [FabFilter — XY Controller / MIDI Learn (Saturn, Volcano, Twin, Pro-Q)](https://www.fabfilter.com/help/pro-q/using/midilearn)
- [Sound on Sound — Cableguys ShaperBox 3 review](https://www.soundonsound.com/reviews/cableguys-shaperbox-3)
- [MIDI.org — MPE (MIDI Polyphonic Expression)](https://midi.org/mpe-midi-polyphonic-expression)
- [JUCE docs — SmoothedValue](https://docs.juce.com/master/classSmoothedValue.html)
- [JUCE Forum — efficient parameter smoothing](https://forum.juce.com/t/efficient-parameter-smoothing/16077)
- [Perfect Circuit — Modular Concepts: What is an Envelope Follower?](https://www.perfectcircuit.com/signal/envelope-followers)
- [Apple Support — multi-segment envelope controls (Alchemy)](https://support.apple.com/guide/logicpro/multiple-segment-envelope-controls-lgsica2ce73e/mac)
- [Steinberg / DevelopersIO — VST3 ProcessData, IParameterChanges, sampleOffset](https://dev.classmethod.jp/en/articles/vst3-plugin-parameter-flow-again-processdata-inputparameterchanges/)
- [VST 3 Interfaces — IParamValueQueue](https://steinbergmedia.github.io/vst3_doc/vstinterfaces/classSteinberg_1_1Vst_1_1IParamValueQueue.html)
- [SuperCollider docs — K2A / control-rate vs audio-rate, 64-sample control period](https://doc.sccode.org/Classes/K2A.html)

Primary-source grounding in the DAW Pro repo itself (no external citation needed, read directly):
`Sources/DAWCore/Effects.swift`, `Sources/DAWCore/Automation.swift`,
`Sources/DAWEngine/Automation/AutomationSchedule.swift`,
`Sources/DAWEngine/Effects/EffectRendering.swift`,
`Sources/DAWEngine/Effects/DelayEffect.swift`,
`Sources/DAWEngine/Instruments/PolySynthInstrument.swift`,
`Sources/DAWCore/Sidechain.swift`, `Sources/DAWCore/TempoMap.swift`,
`Sources/DAWControl/Commands.swift`, `Sources/DAWCore/RenderBlockSize.swift`,
`Sources/DAWCore/EffortField.swift`, `Sources/DAWCore/MIDIControllerRouting.swift`,
`Sources/DAWEngine/MIDISchedule.swift`, `Sources/DAWEngine/InstrumentSourceNode.swift`.
