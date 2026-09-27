# The modulation layer — design and frozen contract (m39-e)

**Item:** m39-e, the gating architecture decision of M39.
**Date:** 2026-09-19. **Author:** `daw-architect`.
**Status:** §7 is a **FROZEN CONTRACT**. Implementers follow it verbatim and deviate only by
amending this document. Everything outside §7 is reasoning, and may be improved on with evidence.
**Precedent for the frozen form:** M19's §2.2 tier table.

**Inputs and their weight.** `docs/research/2026-09-19-plugin-program-inventory.md` §7-§10 was treated
as verified fact; the five `docs/research/2026-09-19-*.md` reports were treated as claims. Where this
document contradicts either, it is because I read the source myself, and the file:line is given.

---

## 0. Source state at the time of writing — read this before checking my line numbers

WARNING: `Sources/DAWEngine/Instruments/PolySynthInstrument.swift` was being edited by m39-g while I
read it, and it moved under me.

| when | bytes | sha1 | `func render` at |
|---|---:|---|---:|
| 03:58 | 36 373 | `ea476bd79d8a4b79c44323e8cec292ccdf2044a2` | `:303` |
| 04:03 | 60 198 | `45e1ee34fbdc6b1db65814801f76ab3fa00587cb` | `:311` |

The per-frame event-dispatch loop was confirmed in **both** states (`:346-357`, then `:355-362` — same
shape). The per-voice findings in §5 (`perVoiceCutoff`, `updateVoiceFilter(at:)`, `Voice.cutoffScale`,
`voiceCount = 16`) were read at the **later** state only. **Cite PolySynth by symbol name, not by line
number, until m39-g lands.** Every other file cited here was quiescent.

---

## 1. Decisions at a glance

| # | Question | Decision |
|---|---|---|
| 1 | Option (d) — split the render quantum at breakpoint times | **SPLIT VERDICT.** Adopted for volume and pan as a per-sample *takeover* stage; **rejected for v1** for the effect-chain walk, with a named falsifier (§2.4, deferred item `m39-e-D1`). |
| 2 | (a) parallel schedule / (b) kind 5 / (c) widen the POD | **ALL THREE REJECTED — no modulation event schedule is built at all.** Sources are closed-form functions of transport sample position; there is nothing to schedule (§3.2). |
| 3 | `storeAutomatedParam(slot:value:)` `(start, end)` migration | **NOT DONE.** Modulation composes with automation *at the value*, so the scalar interface survives untouched. Priced anyway (§6.3): 11 effects + 1 protocol default + 2 no-op conformers + ~6 test files. |
| 4 | Which filter modulation ships | **Shared-coefficient (track-level) filter modulation.** Per-voice filter *envelopes* deferred — and the blocker is per-voice envelope **state and trigger plumbing**, not CPU (§5, measured). |
| 5 | The two-tier smooth/rhythmic split | **FALSIFIED AS STATED, and replaced.** The real split is by **target class**, not by modulator character (§3.1). |
| 6 | "Our control rate is 93.75 Hz" | **Abolished as a concept for our own code.** Every source is evaluated at the position where it is needed. The only genuine control-rate path left is the hosted-AU one, which is warned, not hidden (§8). |
| 7 | Wire surface | **9** commands under `mod.*`. `trigger` rejected, `setValue` renamed `setMacro`, `setSource` added (§7.1). |
| 8 | Target addressing | `AutomationTarget` verbatim, plus m39-b's `.instrumentParam(paramName:)`. One home — m39-b and m39-e agree **by construction, because they are the same enum** (§4). |

**Wire/tool delta: +9 commands, +9 MCP tools.** Do NOT copy an absolute total out of this document —
totals rot. Re-derive with `node scripts/gates/doc-count-drift.mjs`.

---

## 2. Option (d) evaluated first — sub-dividing the render quantum

The brief asks this first because it may make everything else moot. It half does, and the half that
does not is the more interesting half.

### 2.1 What I confirmed of §10, first-hand

Every claim in §10 reproduces at the cited lines in `Sources/DAWEngine/Automation/AutomationRenderer.swift`:

- `applyGainRamp` (`:241-259`) ramps gain **per sample**: `let step = (gainEnd - gainStart) / Double(frameCount)`.
- `applyPan` (`:266-295`) ramps the pan **value** per sample and recomputes `cos`/`sin` per sample.
- `storeEffectParams` (`:162-189`) evaluates `AutomationSchedule.value(at: renderStart, ...)` **once**
  and pushes a scalar through `storeAutomatedParam(slot:value:)`.
- `AutomationSchedule.value(at:points:cursor:)` (`Sources/DAWEngine/Automation/AutomationSchedule.swift:396`)
  takes an arbitrary `Int64` with a cursor, exactly as described.

### 2.2 One thing §10 did not say, and it changes the tier argument

The gain and pan stages are per-sample but they are **chorded across the whole quantum**: they
evaluate the lane at `renderStart` and at `renderStart + frameCount` and interpolate linearly between
them. `AutomationRenderer.swift:106-107` says so in its own words — *"a breakpoint interior to a
quantum is chorded across it (error <= one quantum, spec-accepted)"*.

So a **step** on a volume lane does not arrive late; it arrives **smeared** into a linear ramp across
the entire 512-sample quantum, no matter where inside the quantum it actually falls. For a smooth LFO
that error is negligible. For a trance gate it is a 10.7 ms linear fade whose *midpoint* is pinned to
the quantum centre — up to +/-5.3 ms of position error on top of a transition three times longer than
a gate edge should be.

**Consequence for §10's second conclusion.** "Tremolo and auto-pan are cheaper than any report
claimed" is **true for smooth tremolo and false for gated tremolo**. The existing path already does
the expensive part (per-sample application); what it does not do is place an *edge*. That is precisely
what the modulation stage in §3.3 adds, and it is why that stage is a per-sample *takeover* rather
than a second multiply.

### 2.3 (d) for volume and pan: ADOPTED, in a form that cannot redden a byte-identity gate

A tempting cheap version — segment `applyGainRamp` at breakpoint sample times — is **rejected**:
it changes the rendered output of every existing project that has a breakpoint interior to a quantum.
That behaviour is documented as spec-accepted, several byte-identical render gates depend on it, and
modulation is not a licence to change automation.

**Adopted instead:** a separate `ModulationStage` that **takes over** a target only when at least one
modulation route addresses it. See §3.3. Byte-identity for every existing project is preserved *by
construction* — no project has a route — and a zero-depth route is a positive control that must render
bit-identically to no route at all.

### 2.4 (d) for the effect-chain walk: REJECTED for v1 — three measured obstacles

Sub-blocking the chain walk means calling `EffectChainProcessor.process(bufferList:frameCount:key:)`
K times per quantum over offset windows. The buffer plumbing is the easy part: this tree already
builds preallocated `AudioBufferList`s at `prepare()` time and re-points `mData` every quantum
(`ChainHostAU.swift:280-291` for the key list, `HostedAUEffect.swift:172-179` for the scratch), so an
offset window ABL is an established, allocation-free pattern.

The obstacles are not plumbing. They are **per-walk semantics that assume walk == quantum**:

**Obstacle 1 — the reset countdown is consumed per walk, and that breaks a shipped contract.**
`EffectChainProcessor.swift:422-428`:

```swift
let pendingResets = daw_atomic_u32_exchange(unit.resetFlag, 0)
if pendingResets > 0 {
    unit.instance.reset()
    if pendingResets > 1 { daw_atomic_u32_store(unit.resetFlag, pendingResets - 1) }
}
```

`requestResetAll(passes: 2)` is the m15-f live flush double-arm, and its whole point is that the
**second** pass happens on the **next quantum**, wiping what an in-flight pre-flush quantum leaked
into the just-cleared ring. Walking K times per quantum consumes both passes inside one quantum and
the guarantee silently evaporates. Fixable — hoist the reset consumption above the sub-block loop —
but it is a change to a contract that was paid for in a bug, and it must be an explicit edit, not a
side effect.

**Obstacle 2 — some effects' automated response is tuned to one store per quantum, and sub-blocking
makes it slower, not faster.** `GainEffect.storeAutomatedParam` (`Sources/DAWEngine/Effects/GainEffect.swift:175-180`)
ends in `setGainTarget(..., exact: false)`, a **~5 ms declick ramp restarted on every store**. At 48 kHz
that ramp is ~240 samples. Store once per 512-frame quantum and it completes. Store eight times per
quantum with 64-frame sub-blocks and each store restarts the ramp after it has advanced only 64
samples: the gain now approaches its target geometrically and **lags further behind the lane than it
does today**. The same shape applies anywhere `storeAutomatedParam` starts a fixed-time smoother —
per `EffectRendering.swift:50-57`, that is gain, compressor, gate and limiter.

This is the finding that makes (d) a per-effect question rather than an architectural one: **sub-blocking
does not uniformly improve effect-param modulation; for four of eleven effects it degrades it** unless
each smoother is re-derived against the sub-block length.

**Obstacle 3 — the cost multiplies on the derivation, not on the walk.** Every `storeAutomatedParam`
re-derives the effect's render params. `EffectRendering.swift:48-65` is an audit of exactly that cost:
eq = 4x RBJ coefficient recompute (`sin`/`cos`/`pow`), limiter = `pow` + `exp`, bassEnhancer = 2x RBJ
+ `exp`, bitCrusher = 2x RBJ. K = 8 multiplies all of it by eight, per automated param, per quantum.
That, not the buffer arithmetic, is the price of (d) — and it is the *same* price the synthesis
report's "interpolate across 32-64 sample sub-blocks" quotes, arriving under a different name.

Plus a fourth, bounded but real: `HostedAUEffect.process` calls a third-party render block. K sub-blocks
means K render calls per quantum on a code path that already carries this tree's worst compatibility
history (third-party AUv2 wedging the main actor for minutes). Correctness holds — `hostSampleTime`
advances by `frameCount`, so the AU sees contiguous time — but the risk and the per-call overhead are
multiplied for no benefit an AU param lane can even receive today (AU param lanes are the deferred M4
vii-f upgrade; `.audioUnit` lanes are dropped at schedule-build resolution).

### 2.5 Why rejecting (d) for effects costs less than it looks

The features that actually want sample-exact edges land almost entirely on targets (d) is **not**
needed for:

| feature | target | mechanism that already exists |
|---|---|---|
| trance gate | `.volume` | per-sample stage (§3.3) |
| auto-pan / rhythmic panner | `.pan` | per-sample stage (§3.3) |
| sidechain-style pumping | `.volume` | per-sample stage (§3.3) |
| filter sweep on a synth | instrument cutoff | the instrument's own per-frame loop (§3.2) |
| vibrato / PWM / drift | instrument params | the instrument's own per-frame loop (§3.2) |
| beat repeat, tape stop | a **new effect kind** | owns its internal transport-aware sequencer; the DJ report's own fallback wording |

What is left, and genuinely degraded at quantum rate, is: **stepping an existing effect's parameter
rhythmically** — sixteenth-note `bitCrusher.bits`, gated `delay.mix`. That is a real want and it is
second-order. It is deferred honestly (§7.5 warns on it) rather than paid for with a ninefold
derivation cost and a broken flush contract.

### 2.6 The falsifier — deferred item `m39-e-D1`, so whoever revisits (d) does not re-derive this

Do not reopen (d) by argument. Reopen it with this experiment, in this order:

1. **Partition invariance, per effect.** For each of the 11 built-ins with representative params:
   render 512 frames in one `process` call, and the same input as 8 x 64, into separate buffers.
   Assert **bit-exact equality**. Positive control: perturb one param between the two runs and watch
   the comparison redden. Any effect that fails is one that cannot be sub-blocked without changing
   the sound of unmodulated material. My prediction, from reading all 11: all pass, because every
   loop is per-sample over carried state — but this is a *prediction*, and the whole point of the test
   is that a prediction is not a measurement.
2. **The reset hoist.** Move the `resetFlag` exchange out of the sub-block loop and re-run the m15-f
   flush tests. If they cannot be made green, (d) is dead for the chain walk.
3. **Smoother re-derivation.** For gain/compressor/gate/limiter, make the declick/smoothing time
   derive from the sub-block length so an automated response is invariant to K. Gate: automated gain
   step response at K=1 and K=8 within 0.1 dB at every sample.
4. **Cost.** Measure a 3-insert chain at K=1 vs K=8 with one automated eq param, on the
   `EnginePerformanceContext` telemetry this tree already records. Budget: the whole point of (d) is
   edges; if it costs more than ~15 % of strip DSP time it loses to a purpose-built sequenced effect.

Only after 1-4 is (d) a decision. Until then the chain walk stays one call per quantum.

---

## 3. The architecture

### 3.1 The two-tier split is falsified as stated, and replaced by a better-founded one

The claim under test: *smooth modulators ride the control rate fine, rhythmic modulators need
sample-accurate edges.* Both the modulation and DJ reports reached it independently, and the
inventory correctly warns that they reached it from the same premise, so it is one piece of evidence
rather than two.

**The premise is half wrong, which makes the conclusion wrong in a specific and useful way.** The
premise is "our control rate is 93.75 Hz". §10 already retracts that for gain and pan. I found the
rest of the retraction:

- `SamplerInstrument.swift:1191-1197`, `PolySynthInstrument` (`render`, per §0), and
  `TestToneInstrument.swift:53-61` all run the **identical** per-frame loop with sample-offset event
  dispatch — `for frame in 0..<frameCount { while eventIndex < events.count { ... guard offset <= frame else { break }; apply(event) } }`.
  **Every instrument we ship is already sample-accurate inside the quantum.** There is no control
  rate on this path at all.
- Gain and pan are per-sample but chorded (§2.2).
- Effect params are the one genuine quantum-rate path.

So the honest split is **not** smooth-vs-rhythmic. It is:

| tier | what determines it | paths |
|---|---|---|
| **T1 — sample-exact, free** | the consuming loop is already per-sample | instrument params; volume and pan once the §3.3 stage exists (`.sendLevel` is refused in v1 — §3.3) |
| **T2 — quantum-rate, warned** | the consumer re-derives params once per `process()` | built-in effect params |
| **T3 — render-call-rate, refused or warned** | a hosted AU samples its input once per render call | `.audioUnit` effects, `.soundBank` / `.audioUnit` instruments |

This split is better founded than the original because it is a property of **code I read**, not of the
modulator's musical character. A square-wave LFO on a synth cutoff is T1 and sample-exact; a *smooth*
LFO on `eq.peak1Freq` is T2 and zipper-prone. The original tiering gets both of those backwards.

### 3.2 No modulation event schedule is built — (a), (b) and (c) all lose to a fourth thing

**Frozen law: every modulation source except the envelope follower is a pure function of the transport
sample position.**

```
s = source.evaluate(atSamplePosition: p)        // p = schedule-relative Int64 frame index
```

with **no accumulator, no phase register, no filter state**. An LFO's phase is
`frac(p * cyclesPerSample + phaseOffset)`. A step sequencer's index is
`floor(p / samplesPerStep) mod stepCount`. A sample-and-hold's value is `hash(seed, cycleIndex)`.

Five things follow, and together they are the whole argument:

1. **There is nothing to schedule.** An event schedule exists to carry irregular authored data — notes,
   breakpoints. A closed-form source needs no events, so options (a) `ModulationEventSchedule`,
   (b) kind 5, and (c) widening the 24-byte POD are all answers to a question that dissolves.
   The scoping wall §10 identifies as the only surviving objection to (b) never has to be climbed.
2. **Seek-exactness and loop-exactness are free.** Position-absolute evaluation is the same discipline
   `AutomationSchedule.value(at:)` and `AutomationRenderer.quantumStart` already use, and it is why a
   mid-playback republish re-seeks rather than replays.
3. **Live and offline agree by construction** for every path we own (⚠️ **except the master strip until
   2026-09-27: see §15**) — the single most useful property
   in the whole design, and the hypothesis m39-d must test rather than assume (§8.2).
4. **Block size becomes irrelevant to our own code.** A 512-frame offline block and a 2048-frame live
   hardware buffer evaluate the same function at the same `p`.
5. **Smoothing must therefore be expressed as shape, never as filter state.** A one-pole slew on a
   source output would reintroduce history-dependence and break 2-4 outright. So edge softening is a
   closed-form raised-cosine ramp of width `edgeMs` centred on the edge — deterministic, seek-exact,
   click-free (§7.2). This is a constraint, and it is the constraint that keeps the whole design honest.

**The one exception, declared:** the envelope follower derives from rendered audio and is therefore
stateful. Renders that start from the same transport position are bit-identical; a render that starts
mid-way differs from a full playthrough for roughly `attackMs + releaseMs`. That is stated in
`mod.describe` output and in the MCP tool description rather than hidden.

### 3.3 The three delivery paths

**P1 — instrument params (T1).** The instrument receives the published modulation snapshot through its
own atomic slot and evaluates it inside its existing per-frame loop, at `renderStart + frame`.
No signature change anywhere: `InstrumentRendering` gains **one** main-actor method with a
default no-op, exactly mirroring how `EffectRendering.storeAutomatedParam` has a default-inert
extension so non-participating conformers need no edit:

```swift
// Sources/DAWEngine/InstrumentRendering.swift — additive
@MainActor func publishModulation(_ snapshot: ModulationSnapshot?)
// extension default: {}  → Sampler, TestTone, EventCapture need ZERO edits in v1
```

`render(events:renderStart:frameCount:output:)` is untouched, and `renderStart` is already the
position-absolute anchor P1 needs.

**P2 — volume and pan only (T1 once built).** A `ModulationStage` that **takes over** a target when
and only when at least one enabled route addresses it.

⚠️ **`.sendLevel` is NOT in v1.** `ProjectStore.swift:3494` refuses `.sendLevel` automation lanes with
`automationTargetNotSupported`, and `AutomationRenderer` carries `volumePoints` and `panPoints` only —
there is no send delivery stage to compose into. Promising it here would put a verb in front of
nothing. Refused at §7.4 with reason `sendLevelUnsupported`.

⛔ **The takeover is NOT confined to `AutomationRenderer` — it must join the graph-level override rule
that already exists, or the knob applies twice.** `PlaybackGraph.swift:1534-1537`, verbatim:

> *"Override rule: rolling → the render stage pans, the mixer sits at center; stopped → WYSIWYG
> preview of the lane."*

When no lane is active the **mixer node's own property carries the knob value** (`AutomationRenderer`'s
own doc, `:100-101`: *"No-op when nothing is published (stopped transport: the mixer node's properties
rule)"*). So a stage that multiplied by the base on top of that would apply the knob twice. The fix is
not a new mechanism: **a modulation route joins `activeLane(for:)`'s neutralisation exactly as a lane
does.** The sites are `PlaybackGraph.swift:1522-1545` for tracks and `:1643`, `:1799`, `:1818`,
`:2967`, `:3210` for the master. The predicate becomes "a lane **or** an enabled route addresses this
target"; everything downstream is unchanged.

**Frozen consequence:** one mechanism serves both targets. Volume could have been done as a ratio
multiply and pan could not (equal-power does not decompose), and two mechanisms for two neighbouring
targets is how they drift apart.

Takeover, not a second multiply, and the reason is pan specifically: the automation stage applies
equal-power gains for angle `theta(pan)`. Applying a second equal-power pair for an offset `delta` is
*not* the same as applying one pair for `pan + delta`, and correcting it by ratio divides by zero at
the edges. So when a pan route exists, `applyPan` is skipped and the stage computes
`theta(pan(p) + delta(p))` per sample using the same `unityScale * cos/sin` math. Same for volume.

Placement: immediately adjacent to `automation.apply` at **all three** call sites —
`ChainHostAU.swift:316-334`, `InstrumentSourceNode.swift:914-928` and `:979-984` — and on the master
strip it follows `stagePlacement.volumePreChain`, so the modulation stage is always glued to wherever
the fader actually is. Never two stages, never a stage on the wrong side of the chain.

**P3 — built-in effect params (T2).** `AutomationRenderer.storeEffectParams` sums the modulation
offset into the value it already computes, then pushes the **same scalar** through the **unchanged**
`storeAutomatedParam(slot:value:)`:

```
value = automationOrKnobValue(at: renderStart)     // existing
value = applyRoutes(value, target, p: renderStart) // new, pure, no allocation
units[i].instance.storeAutomatedParam(slot:value:) // unchanged interface
```

One consequence must be handled and is easy to get wrong: today a target with **no** automation lane
never appears in `schedule.effectParamTracks`, so nothing stores it. A modulated-but-unautomated param
therefore needs a **synthetic ONE-POINT HOLD track** carrying the knob value.

⛔ **One point, not zero.** A zero-point track is skipped twice over — `storeEffectParams:174` is
`guard track.points.count > 0 else { continue }`, and `value(at:)`'s own doc says *"`points` must be
non-empty — the empty-target guard is the caller's."* A zero-point synthetic track would be silently
inert, which looks exactly like a route that does nothing.

⚠️ **And it creates a coupling that must be honoured: the knob value is now baked into a published
snapshot, so a knob edit on a modulated-but-unautomated param MUST republish.** Otherwise an agent
turns the knob, the response says it took, and nothing changes until the next transport start — this
tree's characteristic failure mode, and a setter's return is not proof it took. The republish seam is
`PlaybackGraph.applyParameters`, which already runs on every pass. The build site is
`AutomationSchedule.swift:353-370` (`EffectParamLaneSpec` resolution), and the existing hard cap of
`maxEffectParamTracks = 64` (`:60`, with preallocated cursors sized to it in
`AutomationRenderer.swift:55-56`) now has to cover lanes **plus** modulated params — which is why §7.4
caps routes per strip and refuses past it rather than silently dropping, as the current build does.

**P4 — hosted AUs and hosted instruments (T3).** Refused in v1 with the closed-form image ratio in the
refusal message (§8.1). Not silently aliased.

### 3.4 Publication and RT-safety

`ModulationSnapshot` is an immutable POD graph published through the same discipline used by
`EffectChainSnapshot`, `MIDIEventSchedule` and `AutomationSchedule`, with no new mechanism invented:

- heap `daw_atomic_ptr` slot, `Unmanaged.passRetained` on publish, `takeUnretainedValue` on the render
  thread — no retain/release in the render path;
- main-actor retire bin holding displaced snapshots >= 1 s;
- `generation: UInt64` and `timelineID: UInt64` carried with the identical meaning they have on
  `AutomationSchedule` (`:36-53`), so a mid-playback route edit re-seeks instead of restarting;
- sources and routes in **flat, owned `UnsafeBufferPointer`s allocated in `init`** — no Swift `Array`
  machinery on the render thread, verbatim `MIDIEventSchedule`'s storage pattern;
- macro values live in a preallocated `daw_atomic_u32` array (bit-pattern Float), 16 slots, so
  `mod.setMacro` from the control plane is one atomic store and touches nothing else;
- evaluation is pure libm (`sinf`, `floorf`, integer hash) plus arithmetic. No allocation, no locks,
  no ObjC, no actor hops.
- Loops in the render-side evaluator are `while`, **not** `for i in 0..<n`. This is not style: the
  measured note at `EffectChainProcessor.swift:402-412` records that at `-Onone` a `Range` iteration
  raises ~2 malloc/free events *per iteration* inside the render path, and the allocation gates assert
  an absolute zero. Any new render-path loop inherits that law.

---

## 4. Targets — m39-b and m39-e agree by construction, because they are the same enum

The addressing decision is the one place where "agree by coincidence" would be fatal, so the design
removes the possibility: **there is no modulation target type.** `mod.addRoute` takes the identical
flat `{type, sendId?, effectId?, param?}` object that `automation.*` already takes, decoded by the
existing `AutomationTarget` (`Sources/DAWCore/Automation.swift:18-27`, custom `Codable` at `:38-70`).

m39-b's job is to add exactly one case. **This is the shape it must add** (frozen, because m39-e is
specified against it):

```swift
/// One built-in instrument parameter on this track's instrument.
/// NO id: a track has at most one instrument, so the target is unambiguous.
case instrumentParam(paramName: String)
```

- `Discriminator` gains `instrumentParam`; the flat object is `{type:"instrumentParam", param:"cutoffHz"}`,
  reusing the **existing** `param` coding key. No new key, no new id field.
- `valueRange(in track:)` gains a case resolving through a **new one-home spec table**:

```swift
// Sources/DAWCore/InstrumentParams.swift (new file, DAWCore, engine-free)
// Checked 2026-09-19: DAWCore has NO Instruments.swift and NO Modulation.swift. It DOES have
// InstrumentControllerSupport / InstrumentFamilyResolution / InstrumentFrequencyReference — none of
// which is this home. The name mirrors `Effects.swift`, which is where `EffectParamSpec` lives.
public struct InstrumentParamSpec {   // mirrors EffectParamSpec incl. m39-a's `curve`
    public let name: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let unit: String
    public let curve: ParamCurve          // m39-a
    public let modulatable: Modulatable   // §6.1
    public let note: String?
}
public extension InstrumentParamSpec {
    static func specs(for kind: InstrumentKind) -> [InstrumentParamSpec]
}
```

**`InstrumentParamSpec.specs(for:)` is the ONE HOME** and three items must read it, or it will diverge
the way the log-taper heuristic already diverged across two editor models:

| reader | why |
|---|---|
| m39-b | `AutomationTarget.valueRange(in:)` resolution and lane clamping |
| m39-e | route validation, depth normalisation, refusal taxonomy |
| m39-f | `instrument.describeSynth` returns this table verbatim — it must not re-type the numbers |

⚠️ **Slot positionality does NOT transfer.** Effect automation slots are positional and append-only
forever (`storeAutomatedParam(slot:)`). Instrument params are addressed **by name end to end** —
P1 resolves a name to a field at publish time on the main actor, never by index on the render thread.
So `InstrumentParamSpec` arrays may be reordered freely, and **must not** acquire an index-addressed
setter later. Write that down in the file's type doc; it is the single most likely future mistake.

**v1 modulatable instrument params** (the stable pre-m39-g PolySynth surface,
`PolySynthParams`, `Sources/DAWCore/Model.swift:2545-2616`):

| name | range | unit | curve | modulatable |
|---|---|---|---|---|
| `cutoffHz` | 40 - 18 000 | Hz | logarithmic | **yes** |
| `resonance` | 0 - 1 | - | linear | **yes** |
| `gain` | 0 - 1 | - | linear | **yes** |
| `attack` / `decay` / `release` | per spec | s | logarithmic | **yes** (takes effect at the next note-on) |
| `sustain` | 0 - 1 | level | linear | **yes** |
| `waveform` | enum | - | - | **refused** (`modulationTargetUnsupported`, reason `discrete`) |
| `pedalHoldLimit` | 1 - 128 / nil | notes | linear | **refused**, reason `discrete` |

⚠️ **m39-g's new fields are NOT enumerated here on purpose** — that file moved twice while I read it,
and a frozen list of an in-flight surface is a lie with a date on it. **The rule is frozen instead:**
a new instrument param is modulatable iff it is continuous, read on the render path from the params
snapshot, and its consumer either applies it per sample or re-derives cheaply. Anything that is
consumed only at note-on is marked `yes` with the `appliesAtNextNoteOn` note. Anything discrete is
`refused`. Whoever lands m39-g fills in the rows under that rule; the rule is what this document
freezes.

---

## 5. Which filter modulation m39-e ships — and the §8-Correction-2 magnitude is wrong

**m39-e ships shared-coefficient (track-level) filter modulation.** One LFO/follower/macro/step source
drives one cutoff and one resonance for the whole instrument; the coefficient triple is derived once
per evaluation stride, not once per voice.

**Per-voice filter envelopes are deferred** — but not for the reason the inventory gives, and the
difference matters because it changes what the deferred item actually costs.

### 5.1 What I found, and the correction

§8 Correction 2 describes PolySynth as "shared coefficients with per-voice integrator state only", and
concludes that per-voice modulation "multiplies the `tan()`-based derivation by the voice count on
every update". **At the state I read (04:03, sha `45e1ee34`), m39-g has already built the per-voice
half of that**, for velocity/key tracking:

- `Voice` carries its own `svfA1`/`svfA2`/`svfA3` and a frozen `cutoffScale`;
- the render loop reads `perVoiceCutoff ? voices[index].svfA1 : svfA1`;
- `updateVoiceFilter(at:)` derives one voice's triple, and its own doc says it is *"called at note-on
  and on a parameter-generation change — never per sample, which is the whole contract"*;
- a parameter edit on a tracking patch already re-derives **all 16 sounding voices** — the code comment
  calls this *"Sixteen `tan()` calls at a parameter edit"* and accepts it.

So the storage, the per-voice branch and the derivation helper all exist already.

### 5.2 The cost, measured on this machine rather than asserted

I compiled a standalone `swiftc -O` microbenchmark of the exact coefficient triple PolySynth derives
(`g = tan(pi * cutoff / sampleRate)`, `a1 = 1/(1 + g*(g+k))`, `a2 = g*a1`, `a3 = g*a2`), warmed, two runs:

| | run 1 | run 2 |
|---|---:|---:|
| full coefficient triple | **18.16 ns/call** | **11.45 ns/call** |
| bare `tan()` | 2.45 ns/call | 2.32 ns/call |

The triple is dominated by the divide, not by `tan()`. Taking the **worse** figure, 18.2 ns:

| granularity | derivations/s per 16-voice track | CPU |
|---|---:|---:|
| shared coefficient, 32-frame stride | 1 500 | ~0.003 % of a core |
| **per-voice, 32-frame stride** | 24 000 | **~0.04 % of a core** |
| per-voice, per sample | 768 000 | ~1.4 % of a core |

⛔ **So the order-of-magnitude framing in §8 Correction 2 does not survive contact with a stopwatch.**
The 16x *ratio* is real. The absolute base is so small that 16x is still negligible at any sane
stride: per-voice filter modulation at a 32-frame stride costs about four hundredths of one percent
of a core per track. "Scoped as an afternoon and costs a week" is right about the week, but **CPU is
not what buys it**.

⚠️ Two honest caveats. (1) This is a microbenchmark at `-O` in isolation, not the render path; the
test suite builds at `-Onone`, where it will be materially worse, and the implementer must re-measure
in place. (2) It prices *derivation only* — not the added branch in the voice loop, and not cache
effects of touching 16 voice structs per stride.

### 5.3 What the deferred per-voice item actually costs, stated plainly

A per-voice **filter envelope** needs, per voice: an independent ADSR generator with its own stage and
level state, a trigger at note-on and a release at note-off, its own curve handling, interaction with
the existing amplitude envelope's stage machine, and voice-steal semantics that do not leave a filter
open. That is **envelope state and trigger plumbing inside `PolySynthInstrument`** — a structural
change to the voice model, gated by the same byte-identical-default-render gate m39-g is under. It is
a synth-design item, not a modulation-layer item, and that is why it is deferred as **`m39-e-D2`**
rather than folded in here.

**What m39-e does give per-voice work for free:** the modulation snapshot is available inside the
instrument at any frame (P1), so when `m39-e-D2` builds per-voice envelopes it needs no new delivery
mechanism — only the envelope generators themselves.

---

## 6. Built-in effect params — a per-param verdict, not just a rate warning

A rate warning tells an agent whether a 30 Hz LFO will alias. It does not tell it that
`eq.peak1Freq` will zipper at any rate, or that `delay.timeMs` clicks on every step because the read
offset is an `Int`. Both are properties of the *target*, both are verified in source, and both must
be answerable before the route is created.

### 6.1 The `Modulatable` verdict, added to `EffectParamSpec` alongside m39-a's `curve`

```swift
public enum Modulatable: String, Codable, Sendable {
    case yes        // quantum-rate stores are smoothed or inherently smooth
    case warned     // permitted; `mod.addRoute` returns a warning naming the artefact
    case refused    // `mod.addRoute` throws modulationTargetUnsupported
}
```

**Frozen invariant:** modulation refuses a **superset** of what automation refuses. Everything
automation already refuses (`.audioUnit` params, `delay.sync`, `delay.division` —
`Automation.swift:90-97`) modulation also refuses; modulation additionally refuses **discrete**
params, because an LFO cannot meaningfully drive a boolean or a topology switch. Modulation never
permits something automation forbids. A reviewer can check that invariant mechanically, and a test
must (§11).

### 6.2 The frozen table — all 64 params

Evidence column: `S` = the effect has internal smoothing per the render-safety audit at
`Sources/DAWEngine/Effects/EffectRendering.swift:48-65`; `R` = read-offset/integer structure verified
in the effect source; `D` = discrete by construction (the params init `.rounded()`s it, or it is a
boolean/topology switch).

| kind | params | verdict | why |
|---|---|---|---|
| `gain` | `gainLinear` | **yes** | `S` — exact target + ~5 ms declick ramp |
| | `invertPolarity` | **refused** | `D` — binary (`>= 0.5`) |
| `eq` | `lowShelfFreq`, `lowShelfGainDb`, `lowShelfQ`, `peak1Freq`, `peak1GainDb`, `peak1Q`, `peak2Freq`, `peak2GainDb`, `peak2Q`, `highShelfFreq`, `highShelfGainDb`, `highShelfQ`, `highPassFreq`, `lowPassFreq` (14) | **warned** | no smoothing anywhere — 4x RBJ recompute steps at the quantum boundary. This is the zipper case the synthesis report names, and it is the ONLY built-in family where it genuinely bites |
| | `highPassSlopeDbPerOct`, `lowPassSlopeDbPerOct` (2) | **refused** | `D` — filter order is a topology switch (12...24), not a continuum |
| | `highPassEnabled`, `lowShelfEnabled`, `peak1Enabled`, `peak2Enabled`, `highShelfEnabled`, `lowPassEnabled` (6) | **refused** | `D` — boolean |
| `compressor` | `thresholdDb`, `ratio`, `attackMs`, `releaseMs`, `kneeDb`, `makeupDb`, `mix` (7) | **yes** | `S` — the envelope smoother declicks the steps |
| `limiter` | `ceilingDb`, `releaseMs` (2) | **yes** | `S` — lookahead is FIXED, lines never resize |
| | `truePeak` | **refused** | `D` — boolean |
| `reverb` | `damping`, `mix`, `width` (3) | **yes** | arithmetic only, no structural change |
| | `roomSize` (1) | **warned** | arithmetic, unsmoothed comb-feedback step. ALSO: verified mislabeled — it scales comb feedback (RT60), not size (inventory §7). `mod.describe` must say decay, not size |
| | `preDelayMs` (1) | **warned** | `R` — a read offset into a MAX-sized line; every step jumps whole samples |
| `delay` | `feedback`, `mix`, `highCutHz` (3) | **yes** | `S` on `highCutHz` (1 exp); `feedback`/`mix` are scalar |
| | `timeMs` (1) | **warned** | `R` — VERIFIED integer-only: `delaySamples` is an `Int` (`DelayEffect.swift:45`), assigned by `.rounded()` (`:144-145`), read by integer index (`:209-212`). Smooth delay-time modulation is structurally impossible in this effect. The fix is the new tape/BBD kind, not a tuning change |
| | `pingPong` (1) | **refused** | `D` — `.rounded()` in the params init (`Effects.swift:639`) |
| | `sync`, `division` (2) | **refused** | already refused by automation (`Automation.swift:90-97`); control-plane-only, resolved off the render thread |
| `saturator` | `driveDb`, `mix`, `outputDb` (3) | **yes** | stateless shaper |
| `gate` | `thresholdDb`, `attackMs`, `holdMs`, `releaseMs` (4) | **yes** | `S` — attack/release ramps declick the steps |
| `chorus` | `rateHz`, `depthMs`, `mix` (3) | **yes** | arithmetic; depth is math on a MAX-sized interpolated line |
| `bassEnhancer` | `crossoverHz`, `amount`, `mix` (3) | **yes** | `S` — 2x RBJ + 1 exp, detector state fixed |
| `bitCrusher` | `downsampleHz`, `mix` (2) | **yes** | `S` — 2x RBJ cut sections, state fixed |
| | `bits` (1) | **warned** | `D`-ish — `.rounded()` to 1...16 integer steps (`Effects.swift:903`). Permitted because stepping IS the musical intent here, but the steps are audible and the agent is told so |
| | `antiAlias`, `dither` (2) | **refused** | `D` — boolean |
| `audioUnit` | (empty spec surface) | **refused** | `modulationTargetUnsupported`, reason `hostedAudioUnit` — matches automation, which drops `.audioUnit` lanes at schedule-build resolution |

> ⚠️ **DATED POINTER, added 2026-09-20 by m39-ad — read this before quoting the totals below.**
> The table above is a snapshot of the **eleven** kinds that existed when this design was written.
> Ten more kinds have shipped since (flanger, hallReverb, djFilter, ringMod, tapeDelay, stereoWidth,
> phaser, transientShaper, freqShifter, clipper) and one existing row has MOVED: `saturator` is
> **4** params now, not the 3 counted below — m39-ad appended `oversampling`, verdict **refused**.
> The live, measured split today is **89 yes + 20 warned + 22 refused = 131 across 21 param-bearing
> kinds**, and the place that number is *enforced* is `Tests/DAWCoreTests/ModulationTests.swift`,
> which derives it from `EffectParamSpec.specs(for:)` rather than from this prose. Treat the
> per-kind rows below as the *reasoning* — which is still good — and the totals as history.

**Totals: 31 yes, 18 warned, 15 refused = 64.** Counted per kind off the table above and
cross-checked against the inventory's per-kind counts (gain 2, eq 22, compressor 7, limiter 3,
reverb 5, delay 7, saturator 3, gate 4, chorus 3, bassEnhancer 3, bitCrusher 5 = 64). A test must
assert that split against `EffectParamSpec.specs(for:)` across all 11 kinds, so a new param cannot be
added without a verdict.

### 6.3 The `(start, end)` ramp interface — priced, and NOT taken

The question §10 poses: should effect params ramp per sample like gain and pan, which means
`storeAutomatedParam(slot:value:)` grows to `(start, end)`?

**Measured migration cost** (`rtk proxy grep -rn "storeAutomatedParam" Sources/ Tests/`):

| site class | count | what changes |
|---|---:|---|
| protocol requirement + default-inert extension | 1 + 1 | `EffectRendering.swift:66`, `:73` |
| built-in effect implementations | 11 | one per kind |
| no-op conformers (`PassthroughEffect`, `HostedAUEffect`) | 2 | inherit the default; zero edits if the default is kept |
| render-path caller | 1 | `AutomationRenderer.storeEffectParams` |
| test files referencing the setter | 7 | `AutomationFXParamTests`, `BassEnhancerTests`, `BitCrusherTests`, `CompressorMixTests`, `EQv2Tests`, `GainPolarityRenderTests`, `LimiterTruePeakTests` |

So **14 source files and 7 test files, 21 in all** — measured, not estimated:
`rtk proxy grep -rl "storeAutomatedParam" Sources/ Tests/ --include='*.swift' | wc -l` returns 21,
positive-controlled by the same shape on `EffectRendering` returning 16. The 14 source files are the
11 effect implementations, the protocol (`EffectRendering.swift`), the one render-path caller
(`AutomationRenderer.swift`), and one doc-comment reference in `Sources/DAWCore/Automation.swift`.
That is a day of mechanical work, not a week. It is not the reason to decline.

⛔ **The reason to decline is that it does not buy what it looks like it buys.** A `(start, end)` pair
is still a **chord across the quantum** — the same construction as `applyGainRamp`, with the same
property established in §2.2: it smears an edge across the block instead of placing it. It therefore
solves **zipper** and does **not** solve **edge accuracy**. And it solves zipper only for effects that
can interpolate their *derived* state cheaply: for `eq`, the only family where zipper actually bites
(§6.2), ramping the param means either re-deriving RBJ coefficients per sample (~4x the
18 ns triple, per sample, per band) or interpolating the coefficients themselves — which is a DSP
change inside `EQEffect`, not an interface change.

**Decision: do not migrate the interface.** If EQ zipper needs fixing, fix it where it lives —
coefficient interpolation inside `EQEffect`, behind the `warned` verdict that already tells the agent
the truth — and leave the other ten effects' interfaces alone. Filed as **`m39-e-D3`**.

---

# 7. FROZEN CONTRACT

**Everything in §7 is normative. Implementers follow it verbatim. Deviations are made by amending
this section, in a commit that says so — not in code that quietly differs.**

Standing rules this section inherits and does not restate per verb: additive only, never rename a
live command; every verb calls `rejectUnknownKeys(_:verb:)` with its exact key list; out-of-range
scalars **clamp and warn** (the `fx.setParam` / m27-c precedent — reject only what cannot be honoured
at all); `trackId` accepts a track UUID **or** the literal `"master"` through the existing
`parseFXTarget()`; every capability ships a control command, an MCP tool, and a test.

## 7.1 The nine `mod.*` commands

The modulation report proposed `addSource / addRoute / setRouteDepth / setValue / trigger /
removeSource / removeRoute / describe / describeKinds`. Adopted with three amendments, each with its
reason:

- **`trigger` REJECTED.** There is nothing to trigger. §3.2 makes every source a pure function of
  transport position, with no phase register to reset. A verb that implies hidden state would invite
  exactly the state this design exists to avoid. If note-triggered envelopes ever ship (`m39-e-D2`),
  they are triggered by note-ons, not by a wire verb.
- **`setValue` RENAMED `mod.setMacro`.** "Set value" is ambiguous next to `setSource` and
  `setRouteDepth` — an agent cannot tell from the name what it writes. `setMacro` says it. Renaming
  is free here because nothing is live yet; this is precisely the moment to get a name right.
- **`mod.setSource` ADDED.** Without it, changing an LFO's rate means delete-and-recreate, which
  invalidates every route pointing at it. Asymmetric surfaces are how agents get stuck.

| verb | params (exact `rejectUnknownKeys` list) | returns |
|---|---|---|
| `mod.addSource` | `trackId`, `kind`, `params` (object, optional), `name` (string, optional) | `{sourceId, source, warnings}` |
| `mod.setSource` | `trackId`, `sourceId`, `params` (object, optional), `name` (optional) | `{source, warnings}` |
| `mod.removeSource` | `trackId`, `sourceId` | `{removedSourceId, removedRouteIds}` — **cascades**, and names what it cascaded |
| `mod.addRoute` | `trackId`, `sourceId`, `target` (object), `depth` (number), `enabled` (bool, optional, default `true`) | `{routeId, route, warnings}` |
| `mod.setRouteDepth` | `trackId`, `routeId`, `depth` (number, optional), `enabled` (bool, optional) | `{route, warnings}` |
| `mod.removeRoute` | `trackId`, `routeId` | `{removedRouteId}` |
| `mod.setMacro` | `trackId`, `sourceId`, `value` (number 0...1) | `{source, warnings}` |
| `mod.describe` | `trackId` (optional — absent = every strip with modulation), `atBeat` (number, optional) | `{strips:[{trackId, sources, routes, effective}]}` |
| `mod.describeKinds` | none | the static catalogue: every source kind, every param with `range`/`unit`/`default`/`curve`, and the per-target `modulatable` verdicts |

`mod.describe`'s `effective` block is what makes this layer legible to an agent: for each route it
returns the source's value at `atBeat` (default: the current transport position), the target's base
value, and the resulting modulated value — so an agent can answer "what is this actually doing right
now" with one call instead of inferring it. It is also the natural place the `warned` verdict and any
alias warning are repeated, so they are visible after creation and not only at creation.

`mod.removeSource` cascades rather than refusing, matching how deleting an effect cascades its
automation lanes. It names the cascaded route ids in the response, because a silent cascade is how a
caller ends up with a model it did not predict.

## 7.2 Source kinds and their params — ranges, units, defaults, curves

Four kinds in v1. `sampleHold` is an LFO **waveform**, not a fifth kind — it is closed-form
(`hash(seed, cycleIndex)`), so it needs nothing an LFO does not already have.

### `lfo` — output **bipolar** `[-1, 1]` by default

| param | type | range | default | unit | curve | notes |
|---|---|---|---|---|---|---|
| `waveform` | string | `sine` \| `triangle` \| `sawUp` \| `sawDown` \| `square` \| `sampleHold` | `sine` | - | - | `sawUp` rises then resets; `sawDown` falls. Named unambiguously on purpose |
| `rateHz` | number | 0.01 ... 40 | 1.0 | Hz | **logarithmic** | ignored when `syncDivision` is set |
| `syncDivision` | string \| null | any `NoteDivision` raw value (`"1/4"`, `"1/8t"`, `"1/16d"`, 18 in all) | `null` | - | - | **requires m39-c** (see 7.2.1) |
| `phaseDeg` | number | 0 ... 360 | 0 | deg | linear | phase at transport position 0 |
| `pulseWidth` | number | 0.01 ... 0.99 | 0.5 | - | linear | `square` only; warned and ignored otherwise |
| `edgeMs` | number | 0 ... 100 | 2.0 | ms | logarithmic | raised-cosine edge width for `square` / `sampleHold`; ignored on continuous waveforms |
| `bipolar` | bool | - | `true` | - | - | `false` maps output to `[0, 1]` as `(v + 1) / 2` |
| `seed` | integer | 0 ... 65535 | 0 | - | - | `sampleHold` only; makes the random sequence reproducible |

### `stepSequencer` — output **bipolar** `[-1, 1]`

| param | type | range | default | unit | curve | notes |
|---|---|---|---|---|---|---|
| `steps` | array of number | each -1 ... 1; length 1 ... 64 | `[1, 0, 1, 0]` | - | linear | offsets, NOT levels — see the polarity amendment below. A sweep is any ramp |
| `stepDivision` | string | `NoteDivision` raw | `"1/16"` | - | - | **requires m39-c** |
| `edgeMs` | number | 0 ... 100 | 2.0 | ms | logarithmic | raised-cosine edge between steps |

### `envelopeFollower` — output **unipolar** `[0, 1]`. The one stateful source

| param | type | range | default | unit | curve | notes |
|---|---|---|---|---|---|---|
| `source` | string | `"self"` | `"self"` | - | - | v1 accepts **only** `"self"` (this strip's chain input). A cross-strip key is `m39-e-D4` and is refused, not silently self-keyed |
| `detector` | string | `rms` \| `peak` | `rms` | - | - | |
| `attackMs` | number | 0.1 ... 500 | 10 | ms | logarithmic | |
| `releaseMs` | number | 1 ... 2000 | 100 | ms | logarithmic | |
| `floorDb` | number | -90 ... -20 | -60 | dB | linear | input level mapped to output 0 |
| `gainDb` | number | -24 ... +24 | 0 | dB | linear | pre-detector trim |

Creating one always returns the warning `modulationFollowerNonDeterministic` (§7.5) — it is the only
source whose output depends on render history.

### `macro` — output **unipolar** `[0, 1]`

| param | type | range | default | unit | curve |
|---|---|---|---|---|---|
| `value` | number | 0 ... 1 | 0 | - | linear |

Written live by `mod.setMacro`; one `daw_atomic_u32` store (Float bit pattern), 16 macro slots per
strip preallocated at publish.

### 7.2.0 AMENDMENT (2026-09-19, m39-e implementation) — the polarity convention, stated

**Amending §7.2's `steps` annotation, which was measurably wrong.** It read *"a trance gate is
`[1,0,1,0,...]`"*. Run §7.3's own depth law and it is not:

A source output is an **offset**, never a level. `sum = depth · s`, and `sum == 0` means "leave the
target at its base". On `.volume` the fader tops out at +6.02 dB while full depth is 48 dB, so the
only usable direction is **down** and a gate/tremolo **must** take a NEGATIVE depth (§7.3 already
freezes that: *"tremolo and gate patterns are authored `bipolar: false` with a NEGATIVE depth"*).
Under a negative depth:

| step / square level | offset | fader |
|---|---|---|
| `0` | none | **OPEN** — the knob value |
| `1` | −48 dB × \|depth\| | **CLOSED** |

So `[1, 0, 1, 0]` renders **closed-open-closed-open** — it gates the *downbeat* silent, the inverse
of how every reader parses it. **A gate that opens on the downbeat is `[0, 1, 0, 1]`.**

⛔ **This is not fixable by flipping the depth's sign.** "Open" *is* the base, i.e. zero offset;
no sign choice makes `1` mean "open at unity". Flipping the sign turns the cut into a boost the
fader cannot hold.

**Resolution taken — option ⓐ, state the convention; the frozen default VALUE is unchanged.**

- `[1, 0, 1, 0]` remains the default. It is part of the frozen wire/persistence shape, and changing a
  default value is a larger deviation than correcting an annotation that was simply false.
- The convention is now stated in three places an implementer or agent actually arrives at:
  `StepSequencerSourceParams.steps`, `ModulationDepthLaw.volumeGain`, and — the one an agent reads —
  `mod.describeKinds`, which returns it as a `polarity` teaching line per source kind and on the
  `.volume` target.
- A square's `pulseWidth` is the fraction of the cycle at the HIGH value, therefore the **CLOSED**
  fraction on `.volume`. Also stated at all three sites.
- ⓑ (an `invert` flag on the source) was **declined**: it would give two ways to express one thing —
  `invert` and the depth's sign — and a redundant surface is how an agent ends up double-inverting.

**Why this matters more than it looks:** the creative-effects design pass concluded that a
tempo-synced trance gate needs no effect kind at all — it is `stepSequencer → .volume` on this
layer's per-sample path. This convention is the contract for the highest-payoff consumer of the
whole item.

### 7.2.1 Tempo sync is m39-c's job, and m39-e must not hand-roll a second resolver

`syncDivision` / `stepDivision` are resolved to `samplesPerCycle` **on the main actor**, through
m39-c's generalised resolver, and published in the snapshot. The render thread does no tempo maths —
`Automation.swift:90-97` records why (`delay.sync`/`division` are control-plane-only for exactly this
reason).

**m39-e's synced-rate feature is GATED on m39-c.** If m39-c has not landed, ship `rateHz` only and
have `syncDivision` refuse with `modulationTempoSyncUnavailable`. Do **not** copy `DelayTempoSync`'s
`guard effect.kind == .delay` shape into a second place; that duplication is the defect m39-c exists
to remove.

**Declared limitation, warned not hidden:** a synced source follows the tempo in force at the last
publish. A tempo *ramp* inside one render is not followed. Tempo changes already republish (every
stop, seek and tempo change routes through `PlaybackGraph.stopAllPlayers()`), so the ordinary case is
correct; the ramp case returns `modulationTempoRampUnfollowed`.

## 7.3 The depth law — one number, one range, a declared domain per target class

**`depth` is always a unitless number in `[-1, 1]`.** What full depth *means* is declared per target
class. This is the Serum/Vital/Bitwig model and it is why m39-a's `curve` is a hard prerequisite
rather than a nicety.

```
b     = normalise(base, target)                        // -> [0, 1]
sum   = SUM over enabled routes of (depth_i * s_i)     // s_i is the source output
n     = clamp(b + sum, 0, 1)
value = denormalise(n, target)
```

`normalise` / `denormalise` are the inverse pair declared by the target's `curve`:

| curve | normalise | full depth means |
|---|---|---|
| `linear` | `(v - lo) / (hi - lo)` | `+/- (hi - lo)` |
| `logarithmic` | `log(v / lo) / log(hi / lo)` | `+/- log2(hi / lo)` octaves |
| `decibel` | `(dB(v) - dB(lo)) / (dB(hi) - dB(lo))` | `+/- (dB(hi) - dB(lo))` |

⚠️ **`decibel` requires `lo > 0`.** `dB(0)` is `-inf` and the normalisation divides by it. m39-a must
not assign `curve: .decibel` to any range whose lower bound is `<= 0`; a test must assert that across
every spec table. `.volume` sidesteps this entirely because it does not use a spec curve — its domain
is the declared 48 dB window above, not `dB(Track.volumeRange.lowerBound)`.

Worked examples, so there is nothing to interpret:
- `cutoffHz` (40 ... 18 000, logarithmic) spans `log2(18000/40) = 8.81` octaves. **Depth 0.1 is
  +/-0.88 octaves** — a musical vibrato-to-sweep amount, and it means the same thing at 200 Hz as at
  8 kHz. A linear-Hz depth would not, which is the whole argument.
- `resonance` (0 ... 1, linear). Depth 0.25 is +/-0.25.

`.volume` and `.pan` have no `EffectParamSpec`, so their domain is declared here:

| target | domain | full depth | applied as |
|---|---|---|---|
| `.volume` | decibels | `+/- ModulationDepth.volumeFullScaleDb` = **48 dB** | `gain = base * pow(10, sum * 48 / 20)`, clamped to `Track.volumeRange` (0 ... 2) |
| `.pan` | pan units | `+/- 1.0` (hard left to hard right) | `pan = clamp(base + sum, -1, 1)` |
| `.sendLevel` | — | — | **refused in v1** (§3.3, §7.4 `sendLevelUnsupported`) |

⚠️ `base` here is the value the **stage** carries because the stage has taken the target over and the
mixer node has been neutralised (§3.3). It is not a second multiplication on top of the node's own
property. Getting this wrong applies the knob twice and is the single most likely implementation bug
in this contract.

⛔ **Volume modulation is asymmetric at the top, and the contract says so.** `Track.volumeRange` is
`0 ... 2`, i.e. a ceiling of **+6.02 dB**. A bipolar source on `.volume` with a base at unity therefore
clips its upper half while its lower half keeps going — a tremolo that is not a tremolo. **Frozen:
tremolo and gate patterns are authored `bipolar: false` with a NEGATIVE depth (attenuation-only),
which is what the studio idiom means anyway.** `mod.addRoute` emits `modulationVolumeCeiling` (§7.5)
when a bipolar source on `.volume` would exceed the range at the current base.

48 dB is an estimate, and it is **named rather than buried at a call site so it can be argued with** —
the `EffortField.maxAcceptableImageRatio` precedent. At 48 dB, depth 0.125 is a +/-6 dB tremolo, which
is the amount most people mean by "a tremolo".

**Summation order is the published route array order** (which is the store's array order), not a set
iteration. Float addition is not associative; an unspecified order would make a render
non-reproducible. Pinned by test.

**Composition with automation.** `base` is whatever is *in control* of the parameter: the automation
lane's value if a lane is active at that position, otherwise the knob value. `activeLane(for:)`'s
"automation replaces the manual control" law (`Sources/DAWCore/Automation.swift`, moved there at
m26-o so DAWControl and the render path share one predicate) is untouched — **modulation offsets
whatever is in control; it never competes with it.**

## 7.4 Limits and the refusal taxonomy

**Limits, frozen** (every one of these is a preallocation bound on the render thread, not a taste
judgement):

| limit | value | why this number |
|---|---:|---|
| sources per strip | 16 | matches the macro slot array; one atomic word each |
| routes per strip | 64 | matches `AutomationSchedule.maxEffectParamTracks` (`:60`) and the preallocated cursor array (`AutomationRenderer.swift:55-56`) |
| steps per `stepSequencer` | 64 | one cache line of Floats per source, fixed |
| routes per target | unlimited up to the strip cap | summation is defined (§7.3) |

⚠️ **The 64-route cap and the 64-lane cap share one budget and must be checked together.** P3 adds a
synthetic effect-param track for every modulated-but-unautomated effect param (§3.3), so
`lanes + modulatedEffectParams <= 64` on a strip. The existing build **silently drops the excess**
(`AutomationSchedule.swift:91`, `.prefix(Self.maxEffectParamTracks)`). A silent drop is not acceptable
for a route the agent just created, so `mod.addRoute` **refuses** when the combined count would exceed
the cap, and names both contributors in the error. Creating an *automation lane* that would exceed it
keeps its existing behaviour; changing that is out of scope here and is noted as a latent defect in
§12.

**Errors — the refusal taxonomy** (all `LocalizedError`, all naming the legal alternatives, per the
`unknownEffectParam` precedent):

| error | raised when | message must contain |
|---|---|---|
| `modulationSourceNotFound` | unknown `sourceId` on the strip | the id, and the ids that do exist |
| `modulationRouteNotFound` | unknown `routeId` | the id, and the ids that do exist |
| `unknownModulationSourceKind` | `kind` is not one of the four | the offending kind and all valid kinds |
| `unknownModulationParam` | a key in `params` is not in the kind's table | the key, the kind, and the kind's valid param names |
| `modulationSourceKindMismatch` | `mod.setMacro` on a non-`macro` source | the verb, the source's actual kind |
| `modulationTargetUnsupported` | the target's verdict is `refused` | the target, and a `reason` from the frozen set below |
| `modulationLimitExceeded` | a strip cap would be exceeded | which cap, its value, the current count, and — for routes — the lane/route split |
| `modulationStepsInvalid` | `steps` empty, longer than 64, or containing a non-finite value | the offending length or index |
| `modulationTempoSyncUnavailable` | `syncDivision` used before m39-c landed | that m39-c is the prerequisite |

**Frozen `reason` set for `modulationTargetUnsupported`** — an agent branches on these, so they are
part of the contract:

| reason | means |
|---|---|
| `discrete` | boolean, enum, or `.rounded()` param — an LFO cannot drive it meaningfully |
| `hostedAudioUnit` | `.audioUnit` effect param; matches automation, which drops these at schedule-build |
| `hostedInstrument` | `.soundBank` / `.audioUnit` instrument — see §8.1, the message carries the image ratio |
| `controlPlaneOnly` | resolved off the render thread (`delay.sync`, `delay.division`) |
| `unknownParam` | the name is not in the kind's spec table; the message lists the valid names |
| `noInstrument` | `.instrumentParam` on a track with no instrument |
| `crossStripKeyUnsupported` | `envelopeFollower` with a `source` other than `"self"` (`m39-e-D4`) |
| `sendLevelUnsupported` | `.sendLevel` — refused at the store today (`ProjectStore.swift:3494`) and with no render-side send stage to compose into (§3.3) |

## 7.5 Warnings — the honest-answer surface

Warnings never block. They ride the response's `warnings` array, exactly as m27-c's clamp warnings do,
and they are repeated in `mod.describe` so they remain visible after creation.

| warning | when | must carry |
|---|---|---|
| `modulationDepthClamped` | `depth` outside `[-1, 1]` | requested, stored, and the range |
| `modulationParamClamped` | a source param outside its range | param name, requested, stored, range |
| `modulationRateAlias` | the target's delivery path cannot carry the requested rate (§8.1) | requested rate, the path's sampling rate, the image ratio, and the rate ceiling at `maxAcceptableImageRatio` |
| `modulationTargetSteps` | target verdict is `warned` | the target, and the specific reason string from the §6.2 table (zipper / integer read offset / quantised steps) |
| `modulationParamIgnored` | e.g. `pulseWidth` on a non-`square` waveform, `edgeMs` on a continuous one | which param, and under what condition it would apply |
| `modulationRateAndSyncBothGiven` | both `rateHz` and `syncDivision` set | that `syncDivision` wins |
| `modulationVolumeCeiling` | a **bipolar** source routed to `.volume` would exceed `Track.volumeRange`'s +6.02 dB ceiling at the current base | the base, the ceiling, and that attenuation-only (`bipolar:false`, negative depth) is the idiom (§7.3) |
| `modulationFollowerNonDeterministic` | any `envelopeFollower` is created | that renders from the same start position are bit-identical, and partial renders differ for about `attackMs + releaseMs` |
| `modulationTempoRampUnfollowed` | a synced source exists and the tempo map has a ramp in the rendered range | which source, and that it follows the tempo at publish |

## 7.6 Model and persistence

```swift
// Sources/DAWCore/Modulation.swift — new file, DAWCore, UI-free and engine-free
public struct ModulationSource: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ModulationSourceKind       // lfo | stepSequencer | envelopeFollower | macro
    public var name: String                     // agent- and UI-facing label, defaulted from the kind
    public var params: ModulationSourceParams   // a per-kind struct, NOT a dictionary
}

public struct ModulationRoute: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var target: AutomationTarget         // THE SAME ENUM automation uses. One home.
    public var depth: Double                    // clamped to -1...1 at the edit boundary
    public var enabled: Bool
}
```

- `Track` gains `modulationSources: [ModulationSource]` and `modulationRoutes: [ModulationRoute]`,
  both **additive-optional, defaulting to empty**. A project saved before this change decodes and
  renders **byte-identically** after it — the same gate m39-g is under, and it must be
  positive-controlled the same way (default one field non-neutral, watch the comparison redden).
- The master strip carries the same two arrays, reached by `trackId: "master"` through the existing
  `parseFXTarget()`.
- `params` is a **per-kind struct with a custom `Codable`**, not a `[String: Double]`. A dictionary
  would put an unvalidated, undiscoverable surface on disk and in the wire, which is the opposite of
  this milestone's thesis.
- ⚠️ **No positional indices anywhere in this model.** Routes and sources are addressed by UUID,
  targets by name. The append-only slot law (`EffectParamSpec` position == automation slot) applies to
  effect param *arrays* and does not reach this file — and must never be allowed to, because reordering
  a route array is a legitimate edit.

## 7.7 The MCP mirror

Nine tools, one per verb: `mod_add_source`, `mod_set_source`, `mod_remove_source`, `mod_add_route`,
`mod_set_route_depth`, `mod_remove_route`, `mod_set_macro`, `mod_describe`, `mod_describe_kinds`.

- Tool descriptions carry the **depth law worked examples** from §7.3 verbatim. An agent that cannot
  see `curve` will otherwise guess linear Hz, and the guess is silently wrong rather than loudly wrong.
- `mod_describe_kinds` is the discovery entry point and must be named in the other eight descriptions,
  the way `fx.describe` is.
- ⚠️ The MCP bijection test and the `Reference commands` suite are the real tool/command pins;
  `grep -c 'registerTool('` lies. Re-derive both counts with `node scripts/gates/doc-count-drift.mjs`
  after landing, and have every agent **name** any test it retires.
- ⛔ **A `/plugin update` is owed after this lands**, or the user's agents get tool grants without the
  tools. Regenerate and stdio-verify the bundle first — a bundle that is stale at regeneration time
  ships an announcement without its feature.

## 7.8 Stopped transport, and where the follower's state lives

**Stopped transport.** A position-dependent source has no `p` when the transport is stopped, and every
stop, seek and tempo change unpublishes the MIDI and automation schedules through
`PlaybackGraph.stopAllPlayers()`. Frozen behaviour:

| source | stopped |
|---|---|
| `lfo`, `stepSequencer` | **hold neutral** (bipolar -> 0, unipolar -> 0), so a stopped strip sounds like its knobs. This matches the existing "while STOPPED the knobs rule" behaviour for effect params (`PlaybackGraph.swift:1529-1531`) |
| `macro` | **stays live.** It is a control, not a timeline |
| `envelopeFollower` | **stays live.** It follows audio, and audio exists while monitoring a stopped transport |

⛔ **Therefore the modulation snapshot must NOT be unpublished by `stopAllPlayers()`.** It is published
by `applyParameters` and lives across stop; its position-dependent sources return neutral while
stopped, its live sources keep working. This is a **deliberate divergence** from `AutomationSchedule`'s
lifecycle and must be stated in the snapshot's type doc — otherwise someone will tidy it into symmetry
and silently kill stopped-transport macros, which is exactly the workflow an agent uses to dial a
sound in before pressing play.

`mod.describe` at a stopped transport reports each source's stopped value, so the agent, the UI and
the render agree about what is happening rather than three different things.

**Envelope follower state.** An immutable POD snapshot cannot hold a detector envelope. The state
lives in the render-side **`ModulationStage` instance, one per strip, render-thread-only**, in a
fixed-size array indexed by source slot, preallocated at `prepare()` with capacity equal to the
16-source cap. Never allocated on the render thread, never resized. It clears on the same edges effect
tails clear on — `reset()` and the stop-time flush — so a restarted transport does not resume with a
stale envelope, and a removed source leaves an inert slot rather than a dangling one.

---

## 8. Alias warnings, and the m39-d measurement plan

### 8.1 Generalise `EffortField`, do not rebuild it

`EffortField.modulationImageRatio(rateHz:samplingHz:)` (`Sources/DAWCore/EffortField.swift:1061`) and
`modulationRateCeilingHz(samplingHz:maxImageRatio:)` (`:1076`) are closed-form, documented, and
measured against four rates within 3 %. The inverse `f = f_s * r / (1 + r)` is already written down.
**Nothing here gets rebuilt.** What is missing is only the *`samplingHz` for a given route*, so:

```swift
// Sources/DAWCore/Modulation.swift — pure, DAWCore, no engine types
public enum ModulationPath: String, Codable, Sendable {
    case perSample      // T1: volume, pan, and our own instruments
    case perQuantum     // T2: built-in effect params
    case hostedRenderCall  // T3: hosted AU / soundBank
}
public extension ModulationPath {
    /// The rate at which this path samples a modulation signal.
    func samplingHz(sampleRate: Double, blockFrames: Int, stride: Int) -> Double
}
```

- `perSample` with the §11 evaluation stride of 32 gives 1 500 Hz at 48 kHz: a 0.25 image ratio
  ceiling of **300 Hz**. Nothing in the musical modulation band warns. Correct, and it is the payoff
  of §3.2.
- `perQuantum` at the offline 512 gives 93.75 Hz: a ceiling of **18.75 Hz**. So a route onto an
  effect param above ~18.75 Hz warns, with the image ratio and the ceiling in the message.
- `hostedRenderCall` is **refused** in v1 (`modulationTargetUnsupported`, reason `hostedInstrument` /
  `hostedAudioUnit`), and the refusal message carries the image ratio at that path's rate. Refusing
  with the number is the honest answer the roadmap asks for — better than a warning, because there is
  no delivery mechanism behind it at all today.

⚠️ **`maxAcceptableImageRatio = 0.25` is an estimate, named so it can be argued with** (its own doc
says so). Reuse the constant; do not invent a second threshold.

### 8.2 m39-d — and its premise is stale, which changes the plan

⛔⛔ **CHECK THIS BEFORE EXECUTING m39-d.** m39-d's premise is a sentence quoted from
`Sources/DAWCore/RenderBlockSize.swift:58-59`: *"the hardware buffer is device-dependent and
user-changeable, and live playback has never been measured here."*

**That sentence is contradicted, in this repository, by a dated measurement.**
`Sources/DAWCore/MIDIControllerRouting.swift:430-441`, verbatim:

> ⭐ **AND THAT IS NOW MEASURED, NOT ASSUMED (breath pad P6, 2026-08-19).** This sentence previously
> read "at 512 frames the rate is 93.75 Hz" — a conditional dressed as a fact, since nothing had ever
> asked the live path what it hands the renderer. `EnginePerformance` already records
> `lastQuantumFrames` per quantum, so the number was free: a real `AudioEngine`, prepared against this
> machine's default output and left rendering for 400 ms, reported **quantumFrames = 512 at 48 kHz**
> ... with `renderedFrames` an exact multiple of 512 (38912 = 76 x 512), i.e. every quantum the same size.

And `:444-450` of the same file states the consequence explicitly: before m28-bug, **live was 8x finer
than the bounce**, and m28-bug closed that gap by moving the offline block to 512. So the measurement
*predates* the sentence that denies it. Two files, one question, opposite answers, and nothing
compares them — this tree's named characteristic failure mode.

**Three things follow, and they change m39-d's shape and cost:**

1. **The instrument already exists.** `EnginePerformance.Cell.lastQuantumFrames` (`:82`, stored at
   `:185`) is surfaced as `EnginePerformanceStats.quantumFrames` (`:296`). m39-d does not have to
   build a way to see the live block. It has to **read** one, which is most of the measurement.
2. **The divergence is currently ZERO on this machine's default output** — 512 live, 512 offline —
   and that equality is a coincidence of this HAL default, not a guarantee. The routing file says so
   in its own words: *"that equality is a fact about THIS machine's HAL buffer, not a guarantee."*
3. **The genuinely unmeasured question is therefore not "what is the live block" but "what happens
   when it is not 512"** — another device, an aggregate device, BlackHole, or a user-changed buffer.
   That is what m39-d should actually measure, and it is a different experiment from the one the
   item describes.

**Whoever runs m39-d must first re-read both files and reconcile them.** `RenderBlockSize.swift`'s
sentence should be corrected to say what is true — measured on this machine at its default output,
2026-08-19, 512 frames, and a HAL property everywhere else — or the next reader designs around a
constraint that was retired a month ago. A doc fix is a hypothesis; the re-run is the experiment.

### 8.3 The measurement plan

**What is rendered.** One project, four strips, all driven by the same 5 Hz source so the paths are
compared against one stimulus:

| strip | route | path under test |
|---|---|---|
| A | `lfo(5 Hz, sine)` -> `.volume` on a steady 1 kHz tone | T1 per-sample |
| B | `lfo(5 Hz, sine)` -> `eq.peak1GainDb` on a steady 1 kHz tone | T2 per-quantum |
| C | `lfo(15 Hz, sine)` -> `eq.peak1GainDb` | T2 near its 18.75 Hz ceiling — the sensitive case |
| D | `soundBank` track with an 8 Hz CC 11 lane | T3, the already-characterised hosted case |

**What is compared.** For each strip, extract the amplitude envelope and run a Goertzel at the
commanded rate `f` and at the image frequency `|f_s - f|` — the same instrument
`SoundBankHostingTests` T5 used to produce the table now living in `EffortField`'s doc. Compare
**fundamental depth** and **image depth**, offline vs live.

- Offline: the existing `render.*` path at `RenderBlockSize.offlineFrames`.
- Live: capture through **BlackHole 2ch, resolved BY UID (`BlackHole2ch_UID`)** — its device ID changes
  on every `coreaudiod` restart, and `system_profiler` is not authoritative for virtual devices.
- Record `EnginePerformanceStats.quantumFrames` for the live capture and **report it with the result**.
  A live figure without the block size that produced it is not a measurement, it is an anecdote.
- Repeat the live leg at a **second, deliberately different buffer size** (per point 3 above). That
  leg is the actual new information.

**⭐ The positive control, and it is the part that makes the null result meaningful.** Run the identical
comparison between **offline at 512 and offline at 4096**. `RenderBlockSize.swift:39-43` already
records what that divergence looks like with numbers — at 4096 a commanded 11.72 Hz vibrato bounces as
a **static -17.9 cent detune**, and 8 Hz bounces with a 41.7 cent image against a 19.2 cent
fundamental. **If the instrument cannot reproduce that known divergence, the instrument is broken and
its null on the live-vs-offline leg means nothing.** A second control — the same render at depth 0 —
establishes the detector's noise floor, so "the modulation got smaller" and "I measured nothing" cannot
be confused.

**Acceptance, frozen.** If any shipped source rate crosses `maxAcceptableImageRatio` between the live
and offline paths, the modulation layer takes **both** remedies, not one: (i) refuse effect-param
routes above the **worst-case** of the two sampling rates, and (ii) warn at publish with the live
figure. And per the roadmap's own rule, which this design does not relax: **no tempo-synced effect
ships before this is measured.**

---

## 9. Sub-block interpolation — what already ships, what remains, priced

The synthesis report warns that block-stepped coefficients zipper, and prescribes interpolation across
32-64 sample sub-blocks. Applied to *this* tree, most of that prescription is already in production.

**Already shipping, RT-safe, in the render path:**

| mechanism | where |
|---|---|
| per-sample gain ramp (with a bit-exact unity short-circuit) | `AutomationRenderer.applyGainRamp` `:241-259` |
| per-sample pan value ramp with per-sample equal-power trig | `AutomationRenderer.applyPan` `:266-295` |
| per-frame instrument synthesis with sample-offset event dispatch | PolySynth `render`; `SamplerInstrument.swift:1191-1197`; `TestToneInstrument.swift:53-61` |
| per-sample DSP with carried state inside all 11 effects | e.g. `LimiterEffect.swift:336+`, `GainEffect.swift:182-220` |
| internal smoothing on the automated-param path for gain / compressor / gate / limiter | audited at `EffectRendering.swift:48-65` |

**What actually remains to be built** is therefore much smaller than the warning implies:

| remaining work | cost |
|---|---|
| the `ModulationStage` for volume and pan (§3.3) | new, ~150-200 lines, one type + three call-site insertions + the `activeLane` neutralisation predicate at the six `PlaybackGraph` sites |
| the per-stride modulation evaluation inside instruments (P1) | new, but it is a *read* inside a loop that already runs per frame |
| effect-param derivation cadence (T2) stays at one store per quantum | **zero** — deliberately not changed (§2.4, §6.3) |
| EQ coefficient zipper | **the only genuine residue of the warning** — 14 params, one effect, deferred as `m39-e-D3` |

**The evaluation stride, frozen at 32 frames**, with the arithmetic that chose it:

- 32 frames at 48 kHz is a 1 500 Hz update rate; `modulationRateCeilingHz(1500, 0.25)` = **300 Hz**,
  which is six times above the top of the musical modulation band. Nothing authorable warns.
- Coefficient cost at that stride, from the §5.2 measurement (18.2 ns worst case for the full triple):
  ~0.003 % of a core per track shared, ~0.04 % per-voice across 16 voices. Not a budget item.
- For **volume and pan** the stage evaluates the source **per sample**, not per stride, because it
  is affordable: an LFO evaluation is in the same class as the `tan()` I measured at ~2.3 ns, so a
  per-sample sine LFO costs on the order of 0.1-0.2 ms per second of audio per route. Per-sample
  evaluation removes the last approximation on the path that carries trance gates and auto-pan, which
  is exactly where the approximation was audible (§2.2).
- ⚠️ Both figures are **estimates anchored on one measured number**, taken at `-O` in isolation. The
  implementer re-measures in place, through the `EnginePerformance` telemetry that already records
  per-callback render time. If the per-sample stage exceeds ~2 % of strip DSP time, fall back to a
  32-frame stride with a per-sample linear ramp between stride points — that still places an edge to
  within 0.67 ms, sixteen times better than today's 10.7 ms.

---

## 10. The pre-registered hypotheses, one at a time

The inventory's §5.1 holds H1-H5, written before the research landed. Each is answered with evidence,
and two are answered against the author. That is the point of pre-registering them.

### H1 — "Modulation should ride the automation value-delivery path that already exists"
**VERDICT: conclusion CONFIRMED, stated mechanism FALSIFIED in two of three paths.**

H1's mechanism is *"automation already computes one value per parameter per block ... a modulator is
simply another producer of that same per-block value."* Measured:

- **False for volume and pan** — those ramp per sample (`:241-295`). §10 of the inventory already
  retracts this half.
- **False for instruments** — there is no automation path to `track.instrument` **at all**, so there
  is no per-block value to be another producer of. The delivery this design uses (the instrument's own
  per-frame loop) is a different mechanism that H1 did not know existed.
- **True for built-in effect params**, and P3 reuses it literally: modulation composes into the value
  `storeEffectParams` already computes, with the setter interface untouched.

H1's **prediction** — "meaningfully cheaper than its reputation, like M32 halving on measurement" —
**holds, and for a better reason than H1 gave**: not because one delivery point is reusable, but
because two of the three paths are already sample-accurate and need no delivery mechanism invented.

### H2 — "Route per-parameter, not through a fixed matrix"
**VERDICT: CONFIRMED and adopted, with one ergonomic amendment.**

Per-parameter routing with depths is adopted verbatim (§7.3), and H2's reason is stronger than it
claimed: it does not merely *match* `AutomationTarget.effectParam` — it lets modulation **reuse that
exact enum**, which is the mechanism that makes m39-b and m39-e agree by construction (§4).

**Amendment.** H2's example creates the source inline: `mod.add {target:..., source:{lfo, rate:"1/8"},
depth:0.4}`. Rejected. An anonymous inline source cannot be routed to a second target, and changing
its rate means finding every route that copied it — the single most common modulation idiom (one LFO,
three destinations) becomes impossible to express. Sources are first-class and UUID-addressed;
`addSource` then `addRoute`.

### H3 — "Extending `AutomationTarget` to reach instruments buys two features for one change"
**VERDICT: the value CONFIRMED and larger than stated; the COST UNDERSTATED.**

Confirmed as written: `AutomationTarget` has exactly four cases and `.effectParam` resolves strictly
against `track.effects`; nothing reaches `track.instrument`. And the payoff is **three** features, not
two — hand-drawn instrument automation, instrument modulation, and the by-construction agreement
between the two items.

⛔ **But "one change" is wrong, and whoever scopes m39-b should know this before they start.** Adding
the enum case unblocks *addressing*. It does not unblock *delivery*: `AutomationRenderer` has no
instrument path whatsoever — `storeEffectParams` walks `chain.renderSnapshot` and there is no
equivalent for `track.instrument`. So m39-b is **one domain change plus one render-side delivery
path**, and the delivery path is the larger half. The good news is that m39-e builds a delivery
mechanism for exactly this (P1's `publishModulation` slot), so the two items should share it rather
than build two — which is an argument for sequencing m39-b *with* m39-e, not before it.

### H4 — "Generalise the tempo-sync resolver once, before any synced effect is built"
**VERDICT: CONFIRMED, and promoted from advice to a hard prerequisite.**

`syncDivision` and `stepDivision` (§7.2) are the second and third consumers of that resolver. m39-e
must not hand-roll one: `DelayTempoSync`'s `guard effect.kind == .delay` across five intake seams is
the exact duplication m39-c exists to remove, and copying its shape into the modulation layer would
make m39-c's job harder rather than easier. If m39-c has not landed, `syncDivision` refuses with
`modulationTempoSyncUnavailable` and `rateHz` ships alone.

### H5 — "`EffectParamSpec` gains `curve` before any new plugin ships, not after"
**VERDICT: CONFIRMED, and upgraded from hygiene to load-bearing.**

This is the hypothesis the design strengthens most. The depth law (§7.3) is **defined in terms of
`curve`**: without a declared curve, depth on `cutoffHz` cannot mean octaves, and a 0.4-depth LFO
means a different musical gesture at 200 Hz than at 8 kHz — the modulation layer would be wrong at
both ends of every logarithmic range, silently, in a way that looks like a taste problem rather than
a bug.

So **m39-a is a hard prerequisite of m39-e**, not a parallel nicety. H5 argued for `curve` on
append-only grounds (metadata fields are safe, entries are not); the modulation layer supplies a
second, independent and stronger argument that was not available when H5 was written.

### The pre-registered falsifier
H5's section ends: *"if per-block modulation resolution proves audibly too coarse ... H1 is wrong and
modulation needs its own per-sample or smoothed path independent of the automation store."*

**It fired, partially, and it was well chosen.** Per-quantum resolution is too coarse for edges (T2),
and this design does give modulation its own per-sample path — the `ModulationStage` (§3.3) —
independent of the automation store, for the targets where edges matter. It leaves T2 at quantum rate
with a declared per-param verdict rather than pretending otherwise. A pre-registered falsifier that
fires on exactly one of three paths is a good falsifier, and it is the reason this design is shaped by
target class rather than by modulator character.

---

## 11. Implementation plan

### 11.0 Prerequisites, stated as hard or soft

| item | relation to m39-e | if it has not landed |
|---|---|---|
| **m39-a** (`EffectParamSpec.curve`) | **HARD** — the depth law is defined in terms of `curve` (§7.3, §10 H5) | do not start L1. Shipping the depth law without declared curves bakes a musical error into a frozen contract |
| **m39-b** (`AutomationTarget.instrumentParam`) | **CO-DESIGNED** — §4 freezes the case shape; the two items share P1's delivery path | land the enum case as part of L1 rather than duplicating it |
| **m39-c** (tempo-sync resolver) | **SOFT** — gates `syncDivision` / `stepDivision` only | ship `rateHz` only; `syncDivision` refuses with `modulationTempoSyncUnavailable` (§7.2.1) |
| **m39-d** (live/offline block measurement) | **GATES SYNCED EFFECTS**, not the layer | the layer ships; no tempo-synced *effect* ships (§8.3) |

### 11.1 The legs, in order, with file paths

**L1 — DAWCore domain.** Route: `swift-app-engineer`. Headless, no engine, no UI.

| file | change |
|---|---|
| `Sources/DAWCore/Modulation.swift` | **new** — `ModulationSource`, `ModulationRoute`, `ModulationSourceKind`, per-kind param structs with custom `Codable`, `ModulationPath`, the normalise/denormalise pair, the depth law as pure functions |
| `Sources/DAWCore/InstrumentParams.swift` | **new** (with m39-b) — `InstrumentParamSpec` + `specs(for:)`, the ONE HOME m39-b/e/f all read. Name checked against the three existing `Instrument*.swift` files, none of which is this home |
| `Sources/DAWCore/Automation.swift` | `+ case instrumentParam(paramName:)`, its `Discriminator` case, its `valueRange(in:)` resolution (§4) |
| `Sources/DAWCore/Effects.swift` | `+ EffectParamSpec.modulatable`, and the 64 verdicts from §6.2 |
| `Sources/DAWCore/Model.swift` | `Track` (and the master strip) gain `modulationSources` / `modulationRoutes`, additive-optional, default empty |
| `Sources/DAWCore/ProjectStore.swift` | the nine mutations, validation, clamp-and-warn, the refusal taxonomy, the combined lane+route cap check |

⚠️ `ProjectStore.swift` is 472 KB and several agents are editing `DAWCore` concurrently. Grep to the
insertion point; do not read it whole. A `.build` lock means slow, not broken.

**L2 — render side.** Route: `audio-dsp-engineer`. This is the leg with the RT contract.

| file | change |
|---|---|
| `Sources/DAWEngine/Modulation/ModulationSnapshot.swift` | **new** — the immutable published POD graph; owned `UnsafeBufferPointer` storage allocated in `init`, `generation` + `timelineID` with `AutomationSchedule`'s exact semantics, macro `daw_atomic_u32` array |
| `Sources/DAWEngine/Modulation/ModulationEvaluator.swift` | **new** — `evaluate(source, atSample:) -> Float`, pure, `while` loops only, no allocation. The closed-form sources and the raised-cosine edge |
| `Sources/DAWEngine/Modulation/ModulationStage.swift` | **new** — the P2 takeover stage for volume and pan, plus the render-thread envelope-follower state (§7.8) |
| `Sources/DAWEngine/Automation/AutomationRenderer.swift` | `apply(...)` takes an optional borrowed snapshot and **skips** a target the stage takes over; `storeEffectParams` composes the modulation offset into the value it already computes |
| `Sources/DAWEngine/Automation/AutomationSchedule.swift` | the synthetic zero-point track for a modulated-but-unautomated effect param (§3.3), and the cap accounting |
| `Sources/DAWEngine/InstrumentRendering.swift` | `+ @MainActor func publishModulation(_:)` with a **default no-op extension** — Sampler, TestTone and EventCapture need zero edits |
| `Sources/DAWEngine/Instruments/PolySynthInstrument.swift` | adopt the snapshot; evaluate at the 32-frame stride inside the existing per-frame loop. ⚠️ **m39-g is in this file — coordinate, do not merge blind** |
| `Sources/DAWEngine/Effects/ChainHostAU.swift`, `Sources/DAWEngine/InstrumentSourceNode.swift` | insert the stage at the three call sites named in §3.3 |
| `Sources/DAWEngine/PlaybackGraph.swift` | build and publish the snapshot inside `applyParameters` (the seam that already gives live/offline parity for free); extend the `activeLane(for:)` neutralisation predicate at `:1522-1545`, `:1643`, `:1799`, `:1818`, `:2967`, `:3210` to mean "a lane **or** an enabled route" (§3.3); do NOT unpublish the snapshot on `stopAllPlayers()` (§7.8) |

**L3 — wire.** Route: `mcp-integration-engineer`. `Sources/DAWControl/Commands.swift` — the nine verbs
of §7.1. ⚠️ 764 KB; grep to the insertion point. **Place the family beside `fx.*`, not at the tail**,
so every `dropLast(N)` window and suffix assertion in the reference suites stays true by construction —
this is the placement law every recent family (`view.*`, `looper.*`, `au.listPresets`) followed.

**L4 — MCP.** Route: `mcp-integration-engineer`. `mcp-server/src/server.ts` (684 KB, grep) + the
bijection test; then regenerate and stdio-verify `claude-plugin/`; a `/plugin update` is owed
(§7.7).

**L5 — UI.** Route: `ui-design-engineer`. Minimum viable and **not optional**: a modulated parameter's
control must show that it is modulated and show the moving value, or the knob says one thing while the
sound does another. Filed as `m39-e-D5` if it cannot ship with the layer, but it should. **A UI phase
is not done until someone has looked at it** — `debug.captureUI` is the instrument.

### 11.2 Test strategy — the gates that would actually catch a defect here

Ordinary coverage is assumed. These are the ones specific to this design, each with its control:

1. **Byte-identical default render.** A project with no routes renders byte-identically to pre-change.
   **Positive control: default one route's depth non-zero and watch the comparison redden.** A
   byte-comparison that has never failed is indistinguishable from one that compares nothing.
2. **Zero-depth route == no route, bit-exact.** The single most valuable test in the list: it proves
   the takeover stage (§3.3) reproduces the automation stage's arithmetic exactly, which is the one
   place a silent tonal regression could hide. Control: depth `1e-6` must differ.
3. **⭐ Position-absolute determinism.** Render `[0, 10 s)` in one pass, and as `[0, 5 s) + [5 s, 10 s)`
   with a seek between. **Bit-exact** for every source except `envelopeFollower`. This pins the
   no-accumulator law of §3.2 directly, and it is the test that will catch someone "optimising" the
   evaluator with a phase register. **Its own control is built in: the same test on an
   `envelopeFollower` route must FAIL** — the declared exception — so a test that passes everywhere
   is a broken test.
4. **Live/offline agreement** per §8.3, with the offline-512-vs-4096 positive control.
5. **Summation order.** Three routes on one target, added in different orders, must produce the
   documented order's result bit-exactly.
6. **Verdict completeness.** Sum the §6.2 table against `EffectParamSpec.specs(for:)` across all 11
   kinds: **31 yes + 18 warned + 15 refused = 64**. A new param without a verdict fails the build's
   test, not a reviewer's attention. ⚠️ **DATED 2026-09-20 (m39-ad): this mechanism worked exactly
   as designed — every kind added since was forced through it — so the RULE stands, but the NUMBER
   has moved ten kinds' worth. It is 89 + 20 + 22 = 131 over 21 kinds today; see the dated pointer
   above §6.2's totals line. Re-derive from the test, never from this line.**
7. **Refusal-superset invariant.** For every `(kind, param)`: if `AutomationTarget.valueRange` returns
   nil, `mod.addRoute` must refuse. Mechanically checkable; pins §6.1.
8. **RT-safety allocation probe, absolute zero**, on the stage and evaluator — the
   `InsertSpectrumChainTests` pattern. The `while`-not-`for` law applies (`EffectChainProcessor.swift:402-412`).
9. **Cap accounting.** `lanes + modulatedEffectParams > 64` refuses at `mod.addRoute` and names both
   contributors — it must not reach `.prefix(64)` and drop silently.
10. **Wire/MCP pins.** `ZeroParamVerbRejectionTests`, `ReferenceCommandTests`, the MCP bijection test,
    then `node scripts/gates/doc-count-drift.mjs` (exit 0, control fired). Re-derive counts; do not
    copy them. **Name every test retired** — a net delta hides a shrink.

⚠️ **Do not add new `@MainActor` test suites without reading m39-h first.** The occupancy cap is at
380 with an unreachable validation precondition (the campaign requires a median full-suite wall
<= 248 s; the suite measures ~272-276 s, and the PRE-change leg also fails). Add cases to existing
suites. A fourth unbacked bump is worse than no gate.

### 11.3 What needs full Xcode — explicitly

**Nothing in m39-e does.** No entitlements, no AUv3, no code signing, no app bundling. Every leg
builds with `swift build` and tests with `./scripts/test.sh`.

Two adjacent things to keep straight:
- **m39-d's live leg** needs a *running audio device* (BlackHole 2ch, resolved by UID), not Xcode.
- Hosted-AU modulation is **refused** in v1 (§7.4), so the AUv3/entitlement surface is not touched.
  If `m39-e-D6` ever lifts that refusal, AU parameter automation is the deferred M4 vii-f upgrade and
  *that* is where the hosting constraints re-enter.

⚠️ Xcode 26.6 is installed on this machine. Re-triage any item filed "blocked: needs full Xcode"
before re-quoting that blocker.

---

## 12. Deferred, each with the falsifier that would reopen it

| id | what | reopen when |
|---|---|---|
| `m39-e-D1` | sub-blocking the effect-chain walk (option (d) for T2) | the four-step experiment in §2.6 passes — partition invariance per effect, the reset hoist, smoother re-derivation, and a cost under ~15 % of strip DSP |
| `m39-e-D2` | per-voice filter envelopes in PolySynth | the cost is envelope **state and trigger plumbing**, not CPU (§5.2 measured). Reopen as a synth-design item under m39-g's byte-identical-default gate; P1 already delivers the values |
| `m39-e-D3` | EQ coefficient interpolation (the real zipper residue) | someone hears it. 14 params, one effect; `warned` tells the truth meanwhile |
| `m39-e-D4` | cross-strip envelope follower (sidechain key as a modulation source) | reuse `ChainHostAU`'s bus-1 key pull and the `KeyableEffectRendering` seam; the blocker is that the key is a raw audio buffer with no exposed envelope (inventory §3.2) |
| `m39-e-D5` | UI for modulated parameters | should ship with L5; deferred only if the layer would otherwise be blocked |
| `m39-e-D6` | hosted-AU / hosted-instrument modulation | needs the deferred M4 vii-f AU param lane path; refused with its image ratio until then |
| `m39-e-D7` | MIDI CC, velocity and key as modulation sources | they are already sample-accurate on the event path (kinds 2/3/4); the work is routing, not delivery — the one place where a future "kind 5" argument could legitimately return |

⚠️ **One latent defect found in passing, not introduced by this design.** `AutomationSchedule.swift:91`
`.prefix(Self.maxEffectParamTracks)` **silently drops** effect-param lanes past 64. Modulation refuses
rather than drops (§7.4), which means the two surfaces behave differently at the same boundary. Worth
filing separately; do not fix it inside m39-e.

---

## 13. `docs/ARCHITECTURE.md` — the amendment to make when this is adopted

Add to **Key future decisions**, replacing any open entry about modulation:

> **Modulation layer (settled 2026-09-19, m39-e — `docs/design/2026-09-19-modulation-layer.md`).**
> Modulation sources are **pure functions of transport sample position**; no event schedule and no
> phase accumulator exists anywhere. Three delivery paths by target class: instrument params ride the
> instruments' existing per-frame event loop; volume and pan are taken over by a per-sample
> `ModulationStage` adjacent to the fader; built-in effect params compose into the value
> `storeEffectParams` already computes, with `storeAutomatedParam(slot:value:)` **unchanged**.
> Hosted AUs are refused with a closed-form alias figure rather than silently aliased. Routing reuses
> `AutomationTarget` verbatim — modulation and automation address the same targets through the same
> enum, by construction. Depth is a unitless `[-1, 1]` applied in the domain declared by the
> parameter's `curve`, which makes m39-a a hard prerequisite. Sub-blocking the effect-chain walk was
> evaluated and **rejected for v1** on three measured obstacles (§2.4); its falsifier is recorded as
> `m39-e-D1`.

And correct, in the same pass, any place that repeats **"our control rate is 93.75 Hz"** as a
property of the engine. It is a property of **one** path — built-in effect params — and it is false
for gain, pan and every instrument we ship.

---

## 14. ERRATUM — 2026-09-19: the anchor did not survive roll start

§7 is frozen, so this is recorded here rather than edited into it. Nothing in §7's
*design* was wrong; the defect was in the implementation of the publication it
describes, and it made the layer's headline capability inert.

### What shipped broken

An LFO routed to `.volume` or `.pan` had **no effect on the rendered audio at all —
live or offline**. A trance gate rendered byte-identical to an ungated render. The
same applied to the master strip's fader by the identical mechanism.

### The mechanism, measured

§3.2 requires a schedule for a modulation-only strip so the render side has an
ANCHOR — `quantumStart` is how it learns the transport position. `applyParameters`
built and published that anchor correctly, with `requireAnchor = modulatesVolume ||
modulatesPan`.

Then roll start destroyed it. `startAllPlayers` re-published every strip's schedule
from `activeAutomationLanes` alone — a record that carried lanes but **not** the
anchor requirement. For a strip whose only automation is a route, that record is
`(nil, nil, [])`, so the rebuild produced `nil` and published `nil`, wiping the
anchor moments after it was published. `extendLoopAutomation` had the same blind
spot and skipped such strips entirely; both master-side publishes had it too.

`applyParameters` could not recover, and this is the part worth keeping: its publish
gating consulted `requireAnchor` **only** in the branch guarded by
`publishedAutomationLanes[track.id] == nil`. The wipe had just written a non-nil
record, and every lane in it compared equal on every later pass — so the first
branch never fired and the second was unreachable. **A dead state no number of
parameter passes could escape.**

With no schedule, `AutomationRenderer.apply` takes `applyModulationWithoutSchedule`,
where position-dependent sources hold NEUTRAL by design (§7.8, the stopped-transport
case). An LFO therefore contributed exactly zero. That is why the failure was
invisible in loudness: base × (1 + 0) is base, so a gated render came back **not
merely similar but byte-identical** to the control.

### Why 24 passing tests did not catch it

Every m39-e engine test published a hand-built `ModulationSnapshot` **straight to an
`AutomationRenderer`**, then asserted on the stage's output. That tests the stage. It
cannot test the publication, and the defect was entirely in the publication — in a
function none of them called.

> **A hand-published snapshot tests the stage, not the publication.** A test that
> only calls `applyParameters` passes BOTH before and after this fix, because that
> pass was always correct. Only a test that goes through a real render reaches
> `startAllPlayers`, which is where the anchor died.

### The fix

`requireAnchor` became part of the lane bookkeeping (`activeAutomationLanes` /
`publishedAutomationLanes`), so all three publish sites read one truth, and part of
the change detection, so the dead state cannot form. The `= false` default was
removed from `publishAutomation`, `buildRollSchedule` and `publishMasterAutomation`:
**both wipe sites were call sites that simply omitted the argument**, and a default
is what let them. Every call site now states it, and the compiler enforces that a
fourth site must too.

### The gate

`AutomationEngineTests.volumeModulationSurvivesRollStartInOfflineRender` — a real
`OfflineRenderer.render`, with a positive control that the render is not silence
(peak > 0.4), an assertion that an unrouted source is still bit-identical (the
structural byte-identity claim), and the routed assertion the old code failed.
Falsified by reverting the fix: it fails with 2 issues on the original code.
Measured after the fix: 48,760 differing samples, RMS 0.354 → 0.250.

## 15. ERRATUM — 2026-09-27: the master strip never reached a bounce

Claim 3 in §2 ("live and offline agree by construction") was false for the MASTER strip from m39's first
release until W7-ME2 (m39-e-2, 2026-09-27). `graph.masterModulationSources/Routes` were set only on the
LIVE graph (`AudioEngine`); `OfflineRenderer` builds its own `PlaybackGraph` and was never given them. So
a master LFO or macro was heard live and silently absent from every mixdown, bounce and loudness reading.

The fix threads both arrays through `renderOffline`/`renderMixdown` into `OfflineRenderer.beginSession`,
next to `masterAutomation`, before the first parameter pass. The render-class rule follows the master
volume lane: mixdown, bounce, measureLoudness and the stems' "00 Mastered Mix" carry it; each stem, the
"00 Mixdown" reference and bounce-in-place never do (baking it in would apply it twice through the live
master). Gate: `MasterModulationBounceTests` + `MasterModulationBounceSeamTests`, bit-exact against the
engine's formula, with 36 of 42 digests pinned byte-identical.

> **"By construction" held only where the construction reached.** The track strips shared the one
> seam (`applyParameters`); the master strip's publication lived outside it, so nothing forced parity.
