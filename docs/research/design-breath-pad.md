# Design: the Breath Pad — a circular effort-morph controller for wind/bowed realism

**Status: ⭐ PHASE P1 IS BUILT AND GREEN (2026-08-19) — see §11's P1 table for what actually
landed and how it deviates from this plan. P2–P6 are still DESIGN ONLY and unbuilt; the user has
not ruled on them, and may still rule "no" or "only P2".**
(This line previously read "DESIGN ONLY. Nothing here is built." It stopped being true the day
P1 landed, and a stale status line in a document the next cycle reads from is how a plan gets
built twice.)
Author: `daw-architect`. Date: 2026-08-19. Successor to m27 leg D
(`Sources/DAWCore/BreathContour.swift`, shipped today).

---

## 0. Summary and recommendation

The user asked for a way to control *how a simulated player blows* — not just which notes sound —
with standard shapes, dynamic/random flow between shapes, and a circular morph space with a dot
that travels between patterns arranged around a circle. They confirmed the pad should modulate
audibly during playback, and that a simulated player's air budget should actually constrain the
result.

**Recommendation: build shape (a) — the write-mode pad — plus a drag-only audible preview. Do not
build shape (b), a general engine modulation source.**

Concretely, the recommended thing is:

1. A pure DAWCore **effort model** (`EffortField`) that turns *(musical position, seed, path,
   pattern ring)* into an effort value in 0…1. Pure function, no clock, no randomness at call time.
2. A **pattern library** of named effort shapes (messa di voce, hairpin, terraced, sforzando-piano,
   sub-tone entry, breath accent, air-runs-out) placed around a circle.
3. A **dot path** — fixed, orbit, or seeded random walk with momentum — that is a pure function of
   musical position and seed, so it produces the same numbers on every roll and in every bounce.
4. An **air-budget model** that constrains effort and, crucially, *reports* every note it touched.
5. A **commit path** that turns the above into CC/bend lanes through m27 leg D's existing
   `BreathContour` + `applyBreathContour` machinery, which already owns merge semantics, the point
   budget, undo, and the "will this actually sound?" warnings.
6. A **drag-only preview** that streams CC events straight to the render thread while the user is
   physically moving the dot, reusing the m23-d audition ring. No new real-time machinery.

**Why not (b).** A general per-block modulation source in the engine would be the engine's first,
and it would have to re-earn on both instrument paths (`SamplerInstrument` and `HostedAUInstrument`)
something the CC path already gives us for free. Its one unique deliverable over (a) is modulation
that wanders as a function of wall-clock time — which **the user's own reproducibility requirement
forbids**. (b) is milestone-scale work whose distinctive capability we are not allowed to use.

**What (a) genuinely cannot do**, stated precisely rather than waved away, is in §4.3. It is a
short list and the items on it are small.

**What this delivers on the user's actual sax, stated in one place** (the detail is split across
§4.2, §6.2 and §13.6, and split it reads weaker than it is). The sax is a `.soundBank` track hosting
Apple's AUSampler, which receives every controller as raw MIDI (`HostedAUInstrument.swift:203`).

⚠️⚠️ **ALL THREE UNKNOWNS BELOW WERE MEASURED ON 2026-08-19 — `docs/research/measure-gm-sax-cc.md`.
Two answers changed. Do not build from the pre-measurement wording.**

- **Loudness shaping: works, and is *exactly* a gain.** MEASURED: CC 11 on the hosted AUSampler is
  a pure level change following the MIDI square law `(v/127)²`; a single-scalar fit between CC11=127
  and CC11=40 leaves a **−104 dB** residual (the float renderer's floor).
- **Pitch — bend range: CONFIRMED CORRECT.** MEASURED: **±2.0155 semitones**, so leg D's
  `bendRangeSemitones: 2` is right to **0.78 %**. No correction factor is needed.
- ⛔⛔ **Pitch — VIBRATO VIA THE BEND LANE IS BROKEN IN BOUNCES ON THIS PATH.** MEASURED: bend is
  **sample-and-held at the offline render block rate** (`OfflineRenderer.swift:105`, 4096 frames =
  an **11.719 Hz sampler, Nyquist 5.86 Hz**). Leg D's own 5.5 Hz vibrato bounces as *two* vibratos
  beating (35.4 ¢ at 5.50 Hz **plus a 30.0 ¢ alias at 6.22 Hz**); 8 Hz becomes a 3.72 Hz wobble;
  11.72 Hz becomes a static −17.9 ¢ detune. The built-in `.sampler` shows none of it. **The pad must
  not author bend vibrato on a hosted-AU track until this is fixed** — see the CC 1 route below.
  Whether LIVE playback is affected is **NOT MEASURED** (live uses the hardware buffer, not 4096);
  treat "bounce-only" as an untested hypothesis with a one-line falsifying test.
- ⭐ **USE CC 1 FOR SAX VIBRATO.** MEASURED: the DLS sax has its own internal vibrato on CC 1 —
  depth linear in CC1 (`≈ 2.42 + 0.2996 × CC1` cents, ±40.5 ¢ at 127) at a fixed 5.400 Hz. It is
  generated *inside* AUSampler, never crosses our bend lane, and is therefore **completely free of
  the aliasing above**. On the sound-bank path this is both the correct and the better route.
- ⛔ **Brightness / timbre on the sound-bank path: MEASURED, AND THE ANSWER IS NO.** CC 11 moves no
  filter — the −104 dB scalar fit bounds any non-gain difference. The control fired (the same fit
  *refuses* on the built-in sampler's real filter at −9.75 dB, a 95 dB separation), so this is a
  measured negative, not a failed measurement. **The pad on a `.soundBank` track is a loudness-and-
  pitch device. Brightness is a built-in `.sampler` capability only, and no text may promise
  otherwise.**
- **The air budget, the pattern library, the ring, the dot paths and every report: instrument-
  independent.** They shape the effort curve, and the curve reaches both instrument kinds identically.

So the honest summary is **"loudness and pitch on both paths, brightness confirmed only on the
built-in `.sampler`"** — not "a `.sampler` feature with a sound-bank caveat". §6.2 describes the
five-minute render that would settle the brightness question, and §17 asks whether to run it first.

**Rough cost.** Recommended scope: roughly the size of m27 leg D plus a panel — call it one
focused milestone with two or three delegated legs. The preview leg is small (one new push helper,
one contract amendment, one test). Shape (b) is 3–5× that and lands new permanent RT state.

**Nothing here requires full Xcode.** No entitlements, no AUv3, no signing. Everything is
SwiftPM-buildable and testable under `./scripts/test.sh`. §14 says so explicitly and says what
*would* change that.

### 0.1 The decision menu (what the user is actually ruling on)

Each of these can be taken or declined independently. They are ordered so that each one is useful
without the ones below it.

| # | Thing | Rough size | Recommendation |
|---|---|---|---|
| **P1** | Pattern library + `clip.applyEffortShape` (pick one named shape, apply it via leg D) | small | **take** — this alone answers "standard patterns" |
| **P2** | Circular morph space: patterns on a ring, a static dot, blended output | small–medium | **take** — this is the user's own idea and it is cheap once P1 exists |
| **P3** | Dot paths (fixed / orbit / seeded random walk with momentum) | medium | **take** — this is "flow from one pattern to another" |
| **P4** | Air budget, enforced, with per-note legibility | medium | **take** — the user asked for it; §9 is the legibility design |
| **P5** | Physiological humanisation (micro-tremor, 1/f drift) | small | **take** — it is a few lines on top of P3's noise source |
| **P6** | Drag-only live preview through the audition ring | small–medium | **take, but it is the most declinable item** — see §5.4 for exactly what it buys |
| **P7** | The SwiftUI pad panel (the circle, the dot, the drag) | medium | take *if* P6 is taken; without P6 it can be a static editor |
| **B**  | General engine modulation source | large | **decline** — §4 |

A defensible minimum is **P1 + P2 + P4**: named shapes, a circle to blend them, and an honest air
budget, all committed offline through leg D. That is a real feature, ships without touching the
engine at all, and leaves P3/P5/P6 as a clean follow-up.

---

## 1. What already exists (verified today, in this tree)

Everything in this section was read, not remembered. Line references are from the working tree at
branch `m23-wip-2026-08-10`.

### 1.1 m27 leg D — static breath contours, offline

- `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/BreathContour.swift` (656 lines). A free `enum`
  namespace. `BreathContour.generate(noteStartBeat:noteLengthBeats:clipStartBeat:tempoMap:options:)`
  returns a `Generated` carrying an expression run, a pitch-bend run, and **diagnostics**
  (`vibratoStartBeat`, `vibratoTruncatedAtBeat`, `bendSpacingSecondsUsed`,
  `expressionSpacingSecondsUsed`, `noteDurationSeconds`). It is pure: no store, no engine, no
  randomness, no clock.
- `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+BreathContour.swift` (356 lines).
  `applyBreathContour(clipID:noteIDs:options:)` owns selection (all-or-nothing), the load-bearing
  `(startBeat, lengthBeats, id)` sort, **merge-not-replace** lane semantics, the clip-wide
  16384-points-per-lane budget with a coarsen-then-refuse ladder, `performEdit("Breath Contour")`
  undo, and `BreathContourApplication.warnings`.
- Wire verb `clip.applyBreathContour`, `Sources/DAWControl/Commands.swift` name at :297, handler at
  :5164. MCP tool `clip_apply_breath_contour`, `mcp-server/src/server.ts:4423`, bridge send at
  :4644.

**The single most reusable thing leg D shipped is not the curve — it is the result type.**
`BreathContourApplication` proves out the idiom this design needs for the air budget: an edit that
succeeds, returns derived per-run diagnostics, and carries plain-sentence warnings naming what will
*not* be audible and how to fix it. §9 builds the air-budget legibility surface on exactly that
shape.

### 1.2 The CC delivery path — one route, both instrument kinds

- Controller lanes are **baked into the schedule** at build time:
  `MIDIEventSchedule.buildEvents` walks `clip.controllerLanes` (`Sources/DAWEngine/MIDISchedule.swift:216`)
  and emits `ScheduledMIDIEvent` of kind `controlChange` (2) / `pitchBend` (3).
- The schedule crosses to the render thread through `scheduleSlot`
  (`Sources/DAWEngine/InstrumentSourceNode.swift:52`), an atomic pointer slot with a retire bin —
  the same lock-free handoff idiom as `SamplerInstrument.paramsSlot` (:283).
- The render thread slices `[cursor, …)` by sample time (`InstrumentSourceNode.swift:497-514`) and
  hands events to `instrument.apply(...)`.
- **`.sampler`**: `SamplerInstrument.apply` (:1107-1147) writes every controller into a 128-entry
  `ccValues` table and, for an "interesting" controller, recomputes amplitude and filter targets.
  All the expensive math (`exp`, `pow`) happens at *event rate*, never per frame
  (`refreshFilterTarget` :961, `refreshExpressionTargets` :984).
- **`.soundBank` / `.audioUnit`**: the very same `InstrumentSourceNode` drives a
  `HostedAUInstrument` (`PlaybackGraph.swift:523`), which emits raw `0xB0` CC bytes
  (`Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift:203`).

**Consequence that decides the central fork: a CC lane is already the one delivery mechanism that
reaches both instrument kinds.** The user's sax is on the `.soundBank` path. Anything built on CC
lanes works there on day one. Anything built as a new engine modulation source would have to be
re-plumbed into the hosted-AU path separately, and for a hosted AU the only thing you can send is…
a CC. So (b) ends up converting its per-block signal back into CC events anyway, at which point it
has bought nothing on the path the user actually uses.

### 1.3 There is no general modulation source — confirmed, with a positive control

The claim in the brief checks out. A case-sensitive grep for `LFO|Modulator|modulation` across
`Sources/DAWEngine` and `Sources/DAWCore` returns exactly five files —
`Stretch/OfflineStretcher.swift`, `Effects/BassEnhancerEffect.swift`, `Effects/ChorusEffect.swift`,
`SampleLibraries/DSPresetParser.swift`, `SampleLibraries/SampleLibraryIR.swift` — all
effect-internal or importer-side. **Positive control:** the same grep shape run case-insensitively
for `lfo` across all of `Sources/` returns twenty-plus files, so the pattern is capable of matching
broadly and the narrow result is a real absence, not a broken probe.

The closest precedent to a per-block modulation stage is `AutomationRenderer`
(`/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Automation/AutomationRenderer.swift`), held at
`InstrumentSourceNode.swift:65` and applied at :806 / :868 for volume/pan, plus
`storeEffectParams` at :795 / :860 for effect parameters. It reads *authored lanes*; it does not
generate anything.

### 1.4 The two mid-roll republish paths — and the trap

There are exactly two sites in the tree that publish a *non-nil* MIDI schedule:
`PlaybackGraph.swift:3187` (playback start) and `PlaybackGraph.swift:2938` (`extendLoopMIDI`, the
loop unroller's append-only extension). Everything else publishes `nil`.

`extendLoopMIDI` is the seamless one: same `timelineID`, generation bumped, no flush. The render
side then re-seeks by **sample-time watermark**, not by index
(`cursor = MIDIEventSchedule.lowerBound(schedule.events, deliveredThrough)`,
`InstrumentSourceNode.swift:458`). That property is worth stating on its own because it is what
makes a future "regenerate the CC tail" republish thinkable at all: **replacing every event at or
after the delivered watermark is safe by construction; the render side simply re-finds its place.**

⚠️ **The trap, and it is the reason (a) is not simply "rewrite the lane during playback".** A
controller-lane edit is a `ClipKey`-affecting edit. It flows through
`ProjectStore.applyBreathContour` → `engine?.tracksDidChange(tracks)` →
`AudioEngine.tracksDidChangeBody` → `graph.reconcile` flips `changed` →
**`restart(fromBeat: derivedBeats(), …, cause: .continuation)`** (`AudioEngine.swift:1101-1108`).
That is a full player restart with note chase. It is the m23-bp trigger, and its documented,
user-ruled cost is that *a note already mid-decay re-attacks at full velocity*
(`Sources/DAWEngine/RescheduleCause.swift`). Doing that at knob-drag cadence would re-attack the sax
several times a second. **Committing a lane while the transport rolls is therefore a once-per-gesture
operation, never a per-frame one.** This single fact is why the preview in §5 exists.

### 1.5 The live CC route that already exists — the find that makes the preview cheap

`InstrumentSourceNode` holds two lock-free SPSC rings:

- `thruRing` (capacity 512), produced by the **CoreMIDI receive thread**.
- `auditionRing` (capacity 64), produced by the **main actor** — enforced by `@MainActor` on
  `pushAudition(kind:pitch:velocity:)` at `InstrumentSourceNode.swift:348-353`. The doc comment
  says the annotation *is* the SPSC correctness argument: "which thread plays each role is fixed at
  the ring's construction site … the SPSC argument is a type-system property and not a comment".

Both are drained at the top of the render quantum into a preallocated `liveScratch`, merged with
the schedule slice, and handed to `instrument.apply`. Live events sound at offset 0 of the quantum
they drain in.

I read the audition drain (6c, `InstrumentSourceNode.swift:695-744`) rather than assuming it
mirrored the thru drain. **Verified behaviour for a kind-2 (CC) event pushed on the audition ring:**
it falls to the `else` branch at :731-743, which mints a fresh `noteID`, **never touches
`pitchToAuditionID`**, does not change `openAuditionCount`, and emits the event into `liveScratch`
with its `kind`, `pitch` (= controller number) and `velocity` (= value) intact. So it reaches the
instrument correctly, on both instrument kinds, with zero new RT machinery.

⚠️ **But the comment on that branch calls it "a kind audition never produces (2/3/4 — a producer
bug)".** The code path works; the *contract* says CC on this ring is a bug. Using it for a pad
preview therefore requires **deliberately amending that contract** — not quietly relying on the
branch. §5.3 specifies that amendment and the test that pins it. Relying on the branch without
changing the comment would be exactly the "works today, gets 'fixed' next quarter" failure this
tree has been bitten by.

Two more facts checked, because a preview design depends on them:

- **Overflow.** `LiveEventRing.push` returns `false` and release-stores `droppedFlag`
  (`Sources/DAWEngine/MIDIInput/LiveEventRing.swift:66-72`); the render side turns that into
  `auditionCutAll = true` (`InstrumentSourceNode.swift:435-437`), cutting every *open audition
  voice*. With no piano-roll audition open that is a no-op. The ring drains fully every quantum
  (`audTake = min(auditionRing.count, 64)`), so at a 30 Hz push cap and ~93 quanta/s (512 frames at
  48 kHz) it holds 0–1 events; filling 64 slots would need a >2 s audio stall. **The cap is the
  mitigation and it is a number, not a hope.** §5.3 states it.
- **Scratch bounds.** `emitBound = liveCount + 2 * thruTake + 2 * audTake`
  (`InstrumentSourceNode.swift:592`). A CC pop emits exactly one event, so the `2 *` factor is
  conservative for pad traffic and no bound arithmetic changes. This matters: the comment at :530
  records a measured overrun ("11 events written into an 8-slot buffer") from getting this wrong
  once. **Do not add a third ring.** Reusing the audition ring costs no new bound arithmetic;
  a third ring would reopen the most delicate arithmetic on the render thread for no benefit.

---

## 2. The physiology is the spec

The user's goal is "mimic human playing to the max". So the specification is not "add an LFO", it
is "enumerate what a saxophonist's body actually does that a sequencer does not, and expose each
one".

### 2.1 What a wind player independently modulates

Real wind-controller hardware is the best available enumeration of the degrees of freedom, because
its axis list was chosen by people solving exactly this problem. The TEControl **BBC2** exposes
four hands-free continuous axes — **breath** (a piezoelectric transducer sensing breath pressure),
**bite** (force applied to the mouthpiece by teeth/lips), and **nod**/**tilt** (an accelerometer,
head inclination on two axes) — and can send CC, pitch bend or aftertouch on each. [verified —
[tecontrol.se product page](https://www.tecontrol.se/products/usb-midi-breath-bite-controller-2),
[BBC2 user manual PDF](https://www.tecontrol.se/files/MIDI%20BBC2%20Users%20manual.pdf)]

That maps to four physical gestures, of which the first two are the ones that matter here:

1. **Breath pressure** — how hard he blows. Moves loudness *and* brightness *and* pitch together.
   This is the one axis leg D already models.
2. **Embouchure / bite** — lip and jaw pressure on the reed. Moves *timbre and pitch* substantially
   with much less effect on loudness: it is how a player bends into a note, plays sub-tone, or
   keeps a loud note in tune. **This is a genuinely separate axis from breath and this design
   treats it as one.**
3. **Vibrato** — on saxophone produced mainly by the jaw, and physically a *modulation of both*
   breath pressure and embouchure rather than a third independent thing.
4. **Head movement (nod/tilt)** — not physiology, just spare hands-free axes. Out of scope.

The distinction between (1) and (2) is exactly the distinction Audio Modeling's **SWAM** builds its
whole product on: dynamics and fingering are fully independent under physical modelling, every SWAM
instrument *requires* a continuous expression controller, and a separate **Dyn.Harm ("Dynamic
Harmonics")** control decides how much the expression parameter drives overtone content — i.e. how
tightly timbre is coupled to dynamics. [verified —
[SWAM Saxophones](https://audiomodeling.com/products/swam-saxophones),
[SWAM Solo Woodwinds v3.0.0 manual](https://static.audiomodeling.com/manuals/woodwinds/SWAM%20Solo%20Woodwinds%20-%20User%20Manual%20-%20v3.0.0.pdf),
[Audio Modeling KB: velocity-only control](https://kb.audiomodeling.com/support/solutions/articles/206000050973-is-it-possible-to-control-swam-instruments-using-only-note-on-velocity-)]

**Design consequence.** The pad's primary output should be an **effort** value, and effort should
fan out to *at least two* correlated destinations with independently-settable coupling depths —
loudness and brightness — plus a small pitch term. Leg D already implements precisely this fan-out
on the built-in sampler via `SamplerParams.expressionModDepth` / `expressionFilterDepth` /
`expressionFilterCC` (`Sources/DAWCore/Model.swift:1615,1638,1644`), with the documented amplitude
law `amplitude multiplier = (CC11/127) × (1 − d × (1 − dyn))`. The pad should drive that, not
reinvent it.

### 2.2 Numbers, with their provenance marked

This tree has been bitten by derived figures presented as measured, so every number below says
where it came from. Leg D's own `(estimate)` convention is used verbatim.

| Quantity | Figure | Provenance |
|---|---|---|
| Saxophone vibrato rate | **~5 Hz**, associated with a **~10 % variation in blowing pressure** at that rate | **verified in a source**, [Vibrato of saxophones (ResearchGate record)](https://www.researchgate.net/publication/7502176_Vibrato_of_saxophones) — the 10 % pressure figure is the useful half and it is what §7 uses to size tremor against effort |
| Sax vibrato is mostly AM of upper partials, little fundamental change | qualitative | same source. **Design consequence: vibrato that only bends pitch is the wrong model.** Leg D bends pitch only; §6.4 adds the amplitude half |
| Blowing pressure, low dynamics | ~2–3 kPa | **abstract-level only** — I read a search summary of [Objective characterization of saxophone mouthpiece playability](https://www.sciencedirect.com/science/article/abs/pii/S0003682X2300107X), not the paper. Treat as order-of-magnitude |
| Blowing pressure, fortissimo | >120 cm H₂O (≈ 11.8 kPa) | **abstract-level only**, from a summary of [Modeling of Wind Instruments](https://link.springer.com/chapter/10.1007/978-3-662-55004-5_7). Order-of-magnitude |
| Woodwind acoustic dynamic range | ~30 dB | **abstract-level only**, same class of summary. Used only to sanity-check that a ±2.5 dB leg-D contour is an *involuntary* micro-gesture and a written hairpin needs far more |
| Instrumental vibrato band | 5–7 Hz | **(estimate)** — leg D's `vibratoRateHz` doc calls this "conventionally quoted" and unsourced. Unchanged |
| Physiological micro-tremor | 4–8 Hz, deepening with effort | **(estimate)** — I did not find a wind-specific measurement. §7.1 explains why it is still worth shipping and how to make it falsifiable |
| 1/f drift in sustained human control | spectral slope ≈ 1 | **(estimate)** — 1/f noise is well-established generally ([flicker noise](https://en.wikipedia.org/wiki/Flicker_noise)) but I found **no** measurement of it in wind-instrument breath pressure. Marked as a modelling choice, not a finding |
| Comfortable phrase length before a breath | 4–8 s | **(estimate)**, §9.2. Deliberately exposed as a parameter *because* it is unsourced |

⚠️ **The `>120 cm H₂O` and `2–3 kPa` figures come from search-result summaries of paper abstracts,
not from papers I opened.** They are load-bearing for nothing in this design — they only justify
"blowing pressure has a wide, nonlinear working range", which the design uses qualitatively. If an
implementing agent ever wants to put a real pressure curve in the model, those papers must be read
first.

⚠️ **The spike doc `docs/research/spike-wind-instrument-realism.md` carries an
`## 0.0 EMPIRICAL CORRECTION (2026-08-18)` that revises its own §3.x.** Any agent building on this
design must read that correction before quoting the spike, not the body first.

---

## 3. Prior art for the circular morph space

The user's mental image — "a controller with a big circular knob where the dot is moving between
different patterns placed around the circle" — has three distinct pieces of real prior art. All
three were verified for this document; none are recollection.

### 3.1 Sequential Prophet VS (1986) — vector synthesis, the joystick

Four digital oscillators per voice arranged as the extreme points of X and Y axes, labelled A, B,
C, D; the joystick dynamically crossfades between them, and the interesting engineering is
"calculating smooth transitions between the four oscillators … as the user moves the joystick into
positions between the four vector points". [verified — [Prophet VS (Wikipedia)](https://en.wikipedia.org/wiki/Prophet_VS),
[Vector synthesis (Wikipedia)](https://en.wikipedia.org/wiki/Vector_synthesis),
[Sound On Sound Retrozone](https://www.soundonsound.com/reviews/sequential-prophet-vs-retrozone)]

**What we take:** the idea that a 2-D position is a *blend weight generator*, and that the whole
value of the control is the smoothness of the transition — not the corners.

### 3.2 Korg Wavestation (1990) — the vector *envelope*

The blend between four oscillators is varied over time by a dedicated **mix envelope**, in real
time by the joystick, *or* by other controllers such as LFOs and aftertouch. When envelope
modulation is engaged, **the joystick sets the modulation start position** rather than fighting the
envelope. [verified — [Korg Wavestation (Wikipedia)](https://en.wikipedia.org/wiki/Korg_Wavestation),
[Making the most of your Korg Wavestation (SOS)](http://www.chriscarter.co.uk/content/sos/korg_ws_ad.html)]

**What we take — and this is the single most useful borrowed idea in this document:** the joystick
and the automatic motion are not two competing controls. **The hand sets the origin; the automatic
path moves relative to it.** §8 adopts that literally: `dotPath` produces an *offset* from
`dotOrigin`, so grabbing the dot during an orbit relocates the orbit instead of cancelling it.

### 3.3 Spectrasonics Omnisphere — the Orb

"A circular controller": moving the Orb cursor around concentric circles morphs between
automatically generated parameter scenes, patch-dependent. Its movements are plotted on **two
planes, "Angle" and "Radius"**, each assignable to its own MIDI CC. It has an **INERTIA** control
that creates a movement trail after release, "just like a ball might roll and bounce off the walls
of a circular enclosure". It can also be used as a modulation source in the mod matrix. [verified —
[The Orb, Omnisphere 3 manual](https://support.spectrasonics.net/manual/Omnisphere3/30/en/topic/orb-index),
[Orb as Mod Source](https://support.spectrasonics.net/manual/Omnisphere2/25/en/topic/orb-page07),
[Orb MIDI Learn](https://support.spectrasonics.net/manual/Omnisphere/main/orb/page06.html)]

**What we take:** (i) **angle and radius, not x and y** — this is the right coordinate system for a
circular arrangement and it makes "radius = how strongly the pattern is applied" fall out for free;
(ii) **inertia/momentum after release** is the thing that makes the control feel physical, and it
is what the user meant by "flow from one pattern to the other". §8.3 implements momentum
deterministically.

**What we deliberately do NOT take:** the Orb morphs *synth engine parameter scenes*. We are
morphing *effort-over-time curves*, which is a different object with a different interpolation
problem (§7.3). The visual metaphor transfers; the maths does not.

### 3.4 The honest gap in the prior art

None of the three has an **air budget**. Orb inertia is a physics metaphor for a cursor, not for a
player. The air-budget requirement (§9) is the user's own and there is no product to copy — which
is also why §9 spends most of its length on making it *legible* rather than on making it clever.

---

## 4. THE CENTRAL FORK — evaluated

### 4.1 The decision

**Build (a), the write-mode pad, with a drag-only preview. Do not build (b).**

### 4.2 (a) Write-mode pad — what it is and what it costs

The pad computes an effort curve, and *commits* it into CC/pitch-bend lanes through m27 leg D's
existing `applyBreathContour` path. The committed lane is the record and the only thing that ever
plays. While the user is physically dragging the dot, a preview streams CC events through the
audition ring so the gesture is audible; on release the exact contour is committed.

**What it gets right for free:**

| Requirement | How (a) satisfies it |
|---|---|
| Reproducible bounces | The lane *is* the record. Playback and bounce read the same event array. Sample-identical by construction, not by argument |
| Works on the user's actual sax | `.soundBank` → `HostedAUInstrument` → raw `0xB0`. Already the shipping path |
| Editable afterwards | The result is points in the piano roll's controller lane. The user can redraw any of it |
| Undo | `performEdit("Breath Contour")`, already there |
| Agent-controllable | One wire verb, one MCP tool, same shape as leg D |
| Legibility | `BreathContourApplication.warnings` already exists as the idiom (§9) |
| RT safety | **The render thread gains nothing new at all.** No new state, no new allocation, no new branch in the hot loop |

**What it costs:** a DAWCore effort model (pure, testable headless), a generator that maps effort to
leg-D options per note, a store method, a wire verb, an MCP tool, a panel. Plus, if P6 is taken,
one `pushAudition`-shaped helper and a contract amendment on `InstrumentSourceNode` (§5.3).

### 4.3 What (a) genuinely cannot do

Stated precisely, because "(a) is enough" is only credible if the gap is named.

1. **Resolution is bounded by the lane.** Controller lanes are stepwise and capped at
   `maxControllerPointsPerLane` (16384 per lane per clip). Leg D's default expression spacing is
   20 ms; a 4-minute continuous phrase at 20 ms would need ~12000 points on that lane alone.
   Leg D's coarsen-then-refuse ladder handles it and *reports* it (`perNotePointBudget` plus a
   warning sentence), so this degrades visibly rather than silently — but a very long, very dense
   part will get a coarser tremor than asked for. **Estimated practical ceiling: roughly 5 minutes
   of continuous 20 ms expression per clip lane, or ~2 minutes if a dense pitch-bend vibrato lane
   shares the clip.** (This is arithmetic from the 16384 cap, not a measurement.)
2. **Micro-tremor above ~25 Hz is not representable.** At 20 ms spacing the lane Nyquist is 25 Hz.
   The 4–8 Hz tremor band is comfortably inside it; a "growl"/flutter-tongue effect at 20–30 Hz is
   not. Growl is out of scope for (a).
3. **Sub-block timing.** CC events land on schedule sample times, so this is actually *fine* for the
   committed path — but the drag preview lands at quantum granularity (§5.2), which is why the
   preview is explicitly not the record.
4. **Per-voice modulation is impossible, and this is a MIDI 1.0 property, not an (a) limitation.**
   Pitch bend is channel-wide on every instrument in this engine — leg D already documents this
   (`BreathContour.swift:402-408`). A pad cannot make one note of a chord bend independently.
   (b) would not fix this either on the hosted-AU path.
5. **Lane clutter.** Committing dense contours writes thousands of visible points into the piano
   roll's controller lane. That is a UX cost — arguably a *benefit*, since it is what makes the
   result inspectable and editable — but it is real, and §12 proposes a "pad-owned span" marker so a
   re-run replaces rather than accumulates.

Items 1 and 2 are the only ones (b) would fix. Both are small.

### 4.4 (b) A general engine modulation source — evaluated honestly

**What it would be.** A `ModulationSource` protocol in DAWEngine, evaluated per render block, its
output routed to per-voice amplitude/filter/pitch. It would follow the `paramsSlot` idiom
(`SamplerInstrument.swift:283, 612-617, 657, 683`): main actor builds an immutable box, atomic
exchange, ≥1 s retire bin. State lives in the node; evaluation is arithmetic only.

**What it would buy:**

- Audio-rate (or per-block) resolution with no point budget and no lane clutter.
- A reusable substrate: a second modulation source (an LFO on a filter, a random per-note offset)
  would then be cheap. This is the strongest argument for it and it is a real one.
- Tremor above the lane Nyquist.

**Why it loses, in order of decisiveness:**

1. **It does not reach the user's instrument.** For a `.soundBank`/`.audioUnit` track the only
   channel into the plugin is MIDI bytes. A per-block modulation source would have to be
   *re-quantised into CC events* to reach an AUSampler at all — arriving back at (a) with extra
   steps. It would give a real benefit only on the built-in `.sampler`, which is not what the sax
   is on. **A design that only works for one instrument kind must say which, loudly: (b) works
   fully only on `.sampler`.**
2. **Its unique capability is the one the user's constraint forbids.** The only thing (b) can do
   that (a) fundamentally cannot is evaluate as a function of *render time*. Constraint 1 requires
   effort to be a pure function of musical position + seed + path. Once that holds, everything (b)
   computes at render time is knowable at prepare time — which is the definition of "bake it".
3. **Determinism becomes an ongoing obligation instead of a structural property.** Under (a) the
   lane *is* the record, so bounce-equals-playback is true by construction. Under (b) it becomes a
   property that must be re-proved on every change to block sizing, loop unrolling, seek/relocate,
   and the `.offlineRender` chase path. This tree has four `RescheduleCause` cases each with a
   different chase policy; a modulation source has to have a defined answer for all four.
4. **It is the engine's first general modulation source**, so it must also settle: how a source is
   named and persisted, how sources are routed to destinations, how routing survives an instrument
   change, how the offline renderer carries them (`OfflineRenderer.swift:153-199` currently carries
   `masterAutomation: [AutomationLane]` and would need a parallel), what the MCP surface for
   "sources" looks like. That is an architecture, not a feature.
5. **New permanent RT state on a hot path.** Not disqualifying — the `paramsSlot` idiom is proven —
   but it is a permanent increase in the surface that RT-safety review has to cover, bought for
   items 1 and 2 of §4.3.

**Verdict:** (b) is a legitimate future milestone whose justification should be *some other
feature* — a real synth with LFOs, or per-voice random humanisation on the built-in sampler. It
should not be justified by the breath pad, because the breath pad does not need it.

### 4.5 The third option I considered and rejected: schedule-tail republish

Worth recording because it looks attractive and is a trap.

**Shape:** during playback, regenerate the CC events above the delivered watermark and republish
with the same `timelineID`, the way `extendLoopMIDI` does. The render side's value-based re-seek
makes tail replacement structurally safe (§1.4).

**Why it loses:** the only entry point from a model edit is `tracksDidChange`, and that path ends in
`restart(cause: .continuation)` — a full player restart with note chase (§1.4). Getting a seamless
MIDI republish would mean building a *new* engine entry point ("republish this track's MIDI tail
without reconciling"), and then owning its interaction with loop unrolling, `midiRollContext`, the
`midiNoteIDBase` counter, and §8.6 containment pruning. That is a substantial engine change with a
delicate correctness argument, to achieve something the audition ring already achieves for a
gesture, and which committing achieves exactly for the record. **Rejected: highest risk-to-benefit
ratio of the three.**

If a future feature needs continuous non-gestural MIDI generation during playback (a live arpeggiator,
say), this is the right shape and this section is the starting point. It is not needed here.

---

## 5. Constraint 1: "live" must not mean "non-reproducible"

Carried verbatim from the brief:

> **"Live" must not mean "non-reproducible."** If the dot wanders as a function of wall-clock time,
> a bounce will not match what the user heard, and every offline-render gate in this tree stops
> working. effort(t) must be a **pure function of musical position + seed + path** — never elapsed
> real time. Live playback, replay, and offline bounce must agree sample-for-sample. If your design
> cannot hold this, say so explicitly rather than softening it.

**The design holds it, and the way it holds it is a scope line rather than a smoothing argument.**

### 5.1 The determinism law

> **THE PAD LAW.** `effort(b) = F(b, seed, path, patternRing, airBudget)` where `b` is **musical
> position in beats**. `F` contains no reference to wall-clock time, no `Date`, no
> `mach_absolute_time`, no un-seeded RNG, and no mutable state carried between calls. Two
> evaluations of `F` with the same arguments return bit-identical `Double`s. The random walk is a
> **hash of the beat index**, not an incremental accumulator (§8.3), so evaluating at beat 100
> without having evaluated beats 0…99 gives the same answer — which is what makes seek, loop, and
> a bounce starting mid-song all agree.

This law is not a suggestion; §13.1 specifies the test that machine-checks it, including a
**negative control** (change only the seed, assert the output *differs*), because a seed that is
threaded but never read passes every positive test.

### 5.2 The hard split: the lane is the record, the ring is a gesture

There are exactly two audible paths and they have different contracts. Confusing them is how this
requirement gets broken.

| | **Committed lane** | **Drag preview** |
|---|---|---|
| Mechanism | CC/bend points in `clip.controllerLanes`, baked into the schedule | `pushAudition(kind: 2, …)` → audition ring → `liveScratch` → `instrument.apply` |
| When | Always. Normal playback, replay, bounce, stems | **Only while a pointer is down on the pad**, or a `pad.previewValue` wire call is in flight |
| Timing precision | Exact schedule sample time | Offset 0 of whatever quantum the main actor pushed in (~5–20 ms granularity) |
| Reproducible | **Yes, by construction — same array** | **No, and it is not supposed to be** |
| Is it the record? | **Yes** | **No** |

**The rule, stated so an implementing agent cannot get it wrong:**

> **The pad NEVER streams while the transport is simply rolling.** Streaming happens if and only if
> a gesture is in progress. With no gesture in progress, what you hear is the committed lane and
> nothing else. Therefore playback, replay and bounce agree sample-for-sample, always.

This is not a compromise — it is precisely the contract `pushAudition` already carries for
piano-roll note audition: pressing a key in the piano roll makes a sound that is not part of the
song. A pad drag makes a sound that is not part of the song *until you let go*. The user's
"pad live during playback — yes" is satisfied: turning the dot while the transport rolls is
audible immediately.

**The one honest caveat to state to the user:** during a drag, what you hear is an approximation of
the gesture, quantised to the audio block and delivered at whatever rate the UI ran. On release, the
committed contour is computed exactly and may differ slightly in fine timing from what was heard
mid-drag. **This is the same contract as automation write-mode in every DAW**, and it is why the
committed lane is visible and editable.

### 5.3 The preview leg, specified

This is P6. It is the only part of the recommended design that touches DAWEngine.

1. **Amend the audition-ring contract, deliberately.** `InstrumentSourceNode.swift:731-743`'s
   comment currently calls a kind-2/3/4 event on the audition ring "a producer bug". The behaviour
   is correct (mints an ID, never touches `pitchToAuditionID`, emits intact) but the contract must
   be changed to *bless* controller events before anything depends on it. Amend the comment on both
   `pushAudition` (:341-353) and the 6c `else` branch to state: **controller/bend/pressure events
   are a supported audition-ring payload; they pair with no voice, mint a fresh ID, and must never
   touch the pitch map.** Add a test that pins it (§13.4).
2. **Add `pushAuditionController(controller:value:)`** as a thin `@MainActor` wrapper over
   `pushAudition(kind: ScheduledMIDIEvent.controlChange, pitch: controller, velocity: value)`. A
   named entry point, not a raw kind constant at the call site.
3. **Cap the push rate at 30 Hz per track**, enforced on the main actor, with values coalesced
   (send the latest, drop intermediates). Justification is arithmetic, not taste: the ring is
   capacity 64 and drains fully every quantum, so at 30 Hz against ~93 quanta/s it holds 0–1 events
   and overflow needs a >2 s audio stall. **Also emit only on change** — a dot held still pushes
   nothing.
4. **Do not add a third ring.** §1.5 explains: the `emitBound` arithmetic at
   `InstrumentSourceNode.swift:592` has a measured history of being got wrong, and a CC pop emits
   exactly one event so the existing conservative bound already covers pad traffic.
5. **Accept and document one coupling:** if the audition ring ever *does* overflow while a
   piano-roll note audition is open, `auditionCutAll` cuts that audition voice. With no audition
   open it is a no-op. This is a pre-existing property of the ring, not something the pad
   introduces, and at the capped rate it is unreachable.

### 5.4 What P6 actually buys, so it can be declined

Without P6, the pad still works: you set the dot, you apply, you hear it on the next roll (or
immediately, with the `restart(.continuation)` re-attack that every clip edit already causes today).
What P6 buys is **continuous audible feedback while moving the dot** — which is most of what makes
a circular morph controller feel like an instrument rather than a form. If the user wants the
feature to feel like the hardware controller they described, P6 is the part that does that. If they
want the feature to *exist* for the least money, P6 is the first thing to cut.

---

## 6. The effort model

### 6.1 One scalar, several correlated destinations

The pad's primary output is a single scalar **effort** in 0…1 — "how hard is he blowing right
now". This is the right primitive because it is what the physiology says (§2.1): breath pressure is
*one* gesture whose consequences are correlated. A design with independent "volume" and
"brightness" pads would let a user author physically impossible combinations, which is precisely
what makes MIDI sax sound like MIDI.

Effort fans out with independently-settable coupling depths:

| Destination | Mechanism | Depth control | Notes |
|---|---|---|---|
| **Loudness** | CC 11 (expression) lane | `EffortField.loudnessDepth` | Unconditional on `.sampler`; raw `0xB0 0x0B` on `.soundBank` |
| **Brightness** | the CC named by `SamplerParams.expressionFilterCC` (default 11 — the *same* lane) | `SamplerParams.expressionFilterDepth` on the track | ⚠️ **built-in `.sampler` only.** A hosted AUSampler's response to CC11 is the plugin's business |
| **Pitch (micro-sharpening)** | pitch-bend lane | `sharpenCents` (leg D already has it) | Channel-wide. Correct for a mono wind line, wrong for a chord |
| **Vibrato depth** | pitch-bend lane, and (new, §6.4) an AM term on the expression lane | `vibratoDepthCents`, `vibratoAmDepth` | Correlated with effort, not constant |
| **Timbre, second axis** | a *second* CC lane (the "bite" axis, §6.3) | `biteDepth` | Optional. Off by default |

Everything in the first four rows is already reachable through leg D's `BreathContour.Options`.
**The pad's job is to choose those options per note from the effort curve — not to invent a new
delivery mechanism.**

### 6.2 The instrument-kind asymmetry, stated loudly

> ⚠️ **The brightness half of "effort" works fully only on the built-in `.sampler`.** On the
> `.soundBank` path — which is where the user's sax lives — CC 11 arrives at Apple's AUSampler as
> raw MIDI, and whether it moves a filter is the plugin's decision, not ours.
> `MIDIControllerRouting.routing(for:instrument:)` returns `.routed` for `.soundBank` precisely
> because we cannot honestly claim either way
> (`Sources/DAWCore/MIDIControllerRouting.swift:46-51`).

Two consequences for the plan:

1. `MIDIControllerRouting` is the ONE routing table and every pad-facing warning must go through it.
   It is also a file with a history: a previous version confidently asserted that the poly synth
   did not route pitch bend, which was wrong. **Treat it as authoritative only after checking the
   instrument it describes.**
2. **There is an unrun 5-minute experiment that would materially improve this design and it should
   be run before P1 is built** (it is already flagged in the project's open questions): render a
   held note through the stock `gs_instruments.dls` sax and measure (i) whether it honours CC 1
   vibrato, (ii) what AUSampler's real pitch-bend range is — `AUHostRegistry` never configures it,
   so leg D's `bendRangeSemitones: 2` default is **unverified on the sax path**
   (`BreathContour.swift:244-249`), and (iii) whether CC 11 moves brightness at all. If the answer
   to (iii) is "no", the pad on the sax is a loudness-and-pitch device and the doc must say so
   rather than promising a timbre it does not deliver.

### 6.3 The second axis ("bite") — recommended, but off by default

§2.1 established that embouchure is a genuinely separate degree of freedom, and TEControl's product
is built on that separation. Exposing it costs almost nothing here: a second CC lane driven by a
second scalar, with its own coupling depth.

**But it is inert unless something consumes it**, and on the built-in sampler that means pointing
`SamplerParams.expressionFilterCC` at the bite CC instead of at 11 — which then *decouples*
brightness from loudness, which is exactly the SWAM "Dyn.Harm" idea and exactly what leg D's own
doc comment already suggests as the two-lane trick
(`BreathContour.swift:150-156`). **Recommendation: ship the axis, default its depth to 0, and make
the warning path say what to set to make it audible.** That is the `expressionModDepth` precedent
verbatim (`MIDIControllerRouting.swift:91-101`).

### 6.4 One correction to leg D that the physiology demands

Leg D's vibrato is **pitch-only**. The saxophone measurement says vibrato "normally consists of an
amplitude modulation of the upper partials of the tone with little change in the fundamental"
[[Vibrato of saxophones](https://www.researchgate.net/publication/7502176_Vibrato_of_saxophones)],
and is associated with a ~10 % variation in blowing pressure.

**Recommendation: add an amplitude term to vibrato** — an oscillation on the *expression* lane at
the same rate and phase as the bend, with its own depth (`vibratoAmDepth`, suggested default
0.10 of effort travel, taken directly from the 10 % pressure figure). On the built-in `.sampler`
with `expressionFilterDepth` on, that modulates brightness too, which is the closest thing this
engine can do to "AM of the upper partials".

This is a genuine realism gain for a handful of lines and it is the one place where a real
measurement contradicts what we shipped today. It is additive: `vibratoAmDepth` defaults to 0 for
byte-identical behaviour on existing projects, or to 0.10 if the user prefers the better default at
the cost of changing existing renders. **That is a user decision, not mine** — it is a
rendered-bytes change of the same class as m23-bv.

---

## 7. The pattern library

### 7.1 What a "pattern" is

```
Pattern: (scope, curve)
  scope: .note   — the curve spans one note's sounding length
       | .phrase — the curve spans one phrase (onset of first note to end of last, §9.2)
  curve: a small ordered set of knots (u, level), u ∈ [0,1], level ∈ [0,1],
         interpolated with BreathContour.cosineBlend
```

Scope is not decoration. A *messa di voce* is a per-note gesture; a written crescendo is a phrase
gesture; the two must be able to coexist and stack. Reusing `BreathContour.cosineBlend`
(`BreathContour.swift:606-609`) rather than inventing a curve type keeps one interpolation law in
the tree.

### 7.2 The library — evaluated, not adopted wholesale

The brief proposed seven. My assessment of each:

| Pattern | Scope | Keep? | Reasoning |
|---|---|---|---|
| **Messa di voce** (grow then fade, peak in the middle) | note | **yes — the anchor pattern** | It is the classical exercise for exactly this control. Note leg D's default is a *cousin* of this with `peakPosition 0.65`, so the library's version should peak at 0.5 and be recognisably different |
| **Hairpin crescendo** / **diminuendo** | phrase | **yes, as two entries** | Not one entry with a sign. Two entries occupy two positions on the circle, and the dot travelling between them *is* the gesture. Merging them would remove the most musically obvious use of the ring |
| **Terraced** (step to a level and hold) | phrase | **yes** | The baroque/organ contrast to the hairpins, and it is the pattern that makes the circle read as "different characters" rather than "different amounts" |
| **Sforzando-piano** (`sfp`: hard attack, immediate drop, then grow) | note | **yes** | A real notation with a real shape, and it is the only one in the list whose *attack* differs, which broadens what the ring can express |
| **Sub-tone entry** (breathy, low-pressure start rising into tone) | note | **yes, and it is the most sax-specific one** | This is the gesture that says "tenor ballad". ⚠️ Its timbral half is exactly the thing §6.2's unrun experiment governs: without brightness it degrades to a quiet start |
| **Breath accent** (pressure bump at onset without a tongue) | note | **yes, but small** | It is a 60–120 ms feature and mostly overlaps with leg D's existing `attackSettleSeconds`. Keep it as a preset of that rather than a full curve |
| **Air runs out** (decay through the phrase) | phrase | **NO — do not put this in the library** | This is the *air budget's output* (§9), not a shape a player chooses. Putting it on the ring would let the user select "sounds like he ran out of air" while the budget model separately decides he did not — two mechanisms producing the same symptom, which is precisely the "why did this get quiet?" ambiguity constraint 2 forbids. **Rejected on legibility grounds.** |

**Two additions I recommend over the brief's list:**

| Pattern | Scope | Why |
|---|---|---|
| **Flat / neutral** | note | The identity element. Needed at radius 0 anyway (§8.2), and having it explicitly on the ring lets a user park the dot next to it for "barely any shaping" |
| **Late bloom** (straight then a swell in the last third) | note | It is what leg D's `peakPosition 0.65` default already leans toward, and it is the difference between "singing" and "leaning in". Cheap, and it gives the ring a natural opposite to messa di voce |

**Recommended ring: 8 patterns** — flat, messa di voce, late bloom, hairpin cresc., hairpin dim.,
terraced, sforzando-piano, sub-tone entry. Eight is a good number for a circle (45° apart, reads
clearly, and the nearest-two blend in §8.2 always has an unambiguous pair).

### 7.3 THE INTERPOLATION LAW — how patterns blend

This is the part that is not obvious, and getting it wrong produces curves that look blended and
sound like neither parent.

> **THE LAW.** Each pattern is evaluated **in its own normalised domain**, and the results are
> blended **in the value domain**, with weights that sum to exactly 1.
>
> ```
> effortRaw(b) = Σ_i  w_i · pattern_i.level( u_i(b) )
>
>   where u_i(b) = noteRelative(b)   if pattern_i.scope == .note
>                = phraseRelative(b) if pattern_i.scope == .phrase
>   and    Σ_i w_i == 1
> ```

**Why value-domain and not time-domain.** The alternative — warping the time axes into
correspondence and interpolating knot positions — requires a correspondence between the knots of
two different curves. A 2-knot terraced shape and a 5-knot sforzando-piano have no natural
correspondence; any rule you pick (match by index, by order, by nearest-u) produces a different
answer, and each produces visible artefacts at some blend positions. Value-domain blending needs no
correspondence, is O(patterns), is trivially commutative, and has the property that **blending a
pattern with itself returns it exactly** — which is the identity check §13.2 asserts.

**Why this makes different lengths a non-issue.** Normalisation happens *per pattern, in its own
scope*, before blending. A note-scoped pattern on a 4-beat note and a phrase-scoped pattern over 16
beats are both evaluated at the current musical position in their own unit domain, and only their
*outputs* meet. There is no "blending two curves of different lengths" problem left to solve.

**Why linear (equal-gain) weights and NOT equal-power.** The engine's crossfade idiom elsewhere is
equal-power — `SamplerInstrument.ccCrossfadeGain` uses `sqrt`, correctly, because it crossfades
*uncorrelated audio*. Control curves are the opposite case: they are highly correlated, and
blending two identical curves must return that curve. Equal-power would return it scaled by
√0.5 + √0.5 ≈ 1.414. **Use equal-gain (weights summing to 1), with the *weight parameter* eased by
`cosineBlend` so there is no slope discontinuity as the dot passes a pattern.** Recording this
because "the tree uses equal-power for crossfades" is exactly the kind of local consistency that
would produce a wrong answer here.

---

## 8. The circular morph space and the dot

### 8.1 Coordinates: angle and radius, not x and y

Taken from the Orb (§3.3), which plots on "Angle" and "Radius" planes. For a *circular arrangement
of patterns* this is strictly better than x/y:

- **Angle φ** selects *which* patterns blend — the musical character.
- **Radius r** selects *how much* — the depth of the shaping.

That decomposition is what makes "turn it down" a single, obvious control, and it means the two
axes can be assigned to two independent controllers (the Orb's MIDI-learn model) or automated
separately.

### 8.2 The weight law

Patterns sit at evenly spaced angles θ_i = 2πi/N. For a dot at angle φ:

1. Find the two neighbouring patterns `a`, `b` that bracket φ. Let
   `t = (φ − θ_a) / (θ_b − θ_a)` ∈ [0,1).
2. `w_b = BreathContour.cosineBlend(0, 1, t)`, `w_a = 1 − w_b`. All other weights 0.
3. Blend per §7.3 to get `effortShaped(b)`.
4. Apply radius: `effort(b) = neutral + r · (effortShaped(b) − neutral)`, where `neutral` is the
   flat-pattern level (a constant, default 0.5 — **(estimate)**, chosen so radius 0 is a neutral
   mid-effort rather than silence).

**Nearest-two, not a global kernel.** The two alternatives:

- *Inverse-distance (Shepard) weighting over all N patterns.* Loses: it is singular at pattern
  positions, requires an epsilon fudge, and — decisively — it means **every pattern contaminates
  every dot position**, so parking the dot exactly on "terraced" does not give you terraced. The
  ability to select one pattern exactly is the whole point of placing them on a circle.
- *Angular raised-cosine kernel with a tunable span.* Loses on complexity for no gain: at span =
  one spacing it degenerates to exactly the nearest-two rule above; wider spans reintroduce the
  contamination problem; and it adds a parameter with no musical meaning.

**Properties this law has, which the tests in §13.2 assert:** partition of unity (weights sum to 1
everywhere); exact reproduction (`φ = θ_i, r = 1` ⟹ `effort == pattern_i`); continuity including at
the 0/2π wrap; C¹ continuity at pattern positions (from the cosine ease); and commutativity of the
pattern ordering around the ring.

### 8.3 Dot paths — and the one that requires real care

A `DotPath` maps musical position to a dot position. **Every variant must be a pure function of
beat.** The Wavestation lesson (§3.2) is adopted: the path produces an *offset from an origin*, and
the origin is what the hand sets — so grabbing the dot during an orbit relocates the orbit rather
than cancelling it.

| Path | Definition | Pure? |
|---|---|---|
| `.fixed` | `(φ, r)` constant | trivially |
| `.orbit(revolutionBeats:radius:phase:direction:)` | `φ(b) = φ₀ + 2π·(b/revolutionBeats)·dir` | yes — `b` is beats |
| `.drift(seed:scaleBeats:octaves:momentum:radiusRange:)` | seeded fBm field, §8.4 | yes — **by construction, see below** |
| `.drawn(points:)` | authored `(beat, φ, r)` knots, cosine-interpolated | yes |
| `.musical(...)` | φ and r derived from the notes themselves (density → radius, melodic contour → angle) | yes — notes are data |

`.drawn` is worth calling out as more than a fallback: it is what makes the pad *editable*, and it
is the natural target of "record my dot drag" if that is ever wanted (the drag samples become
`.drawn` knots at commit time — same idiom as automation write-mode).

### 8.4 The seeded random walk: why an integrating walk LOSES

This is the single subtlest correctness point in the design.

The obvious implementation of "random walk with momentum" is an accumulator:
`v ← momentum·v + ε; p ← p + v`, stepped once per unit of time. **It must not be used.** It is
*deterministic given a seed*, so it passes the naive reproducibility test — and it is still wrong,
because it is **not position-pure**: `p(b)` depends on having evaluated every step from 0 to `b`.
The consequences are all real and all silent:

- A bounce of bars 33–48 takes a different path than playing the song from bar 1 through bar 48.
- Seeking backward and playing again gives a different result.
- The loop unroller's per-cycle `buildEvents` from `loop.startBeat`
  (`PlaybackGraph.swift:2923-2930`) would produce a different path on cycle 5 than on cycle 1 for
  the *same* musical bars.

Each of those is a "returns a plausible-looking answer while being wrong" failure — this tree's
characteristic mode.

**Use instead: fractional Brownian motion over hashed value noise.**

```
noise1D(seed, k)         = hash(seed, k) → Double in [-1, 1]      // integer lattice, stateless
smoothNoise(seed, x)     = cosineBlend(noise1D(seed, ⌊x⌋), noise1D(seed, ⌊x⌋+1), frac(x))
fbm(seed, x, octaves, m) = Σ_{j<octaves}  m^j · smoothNoise(seed⊕j, x · 2^j)   / Σ_j m^j

φ_offset(b) = angleSwing · fbm(seed,   b / scaleBeats, octaves, momentum)
r(b)        = rMid + rHalf · fbm(seed^1, b / scaleBeats, octaves, momentum)
```

- **Position-pure.** `fbm(seed, x)` reads only `x`. Evaluating at beat 100 cold gives the same
  answer as arriving there. Seek, loop, and mid-song bounce all agree — structurally, not by
  discipline.
- **"Momentum" is the spectral tilt.** `momentum` (the fBm persistence) is *exactly* the user's
  "flow from one pattern to the other": high momentum ⟹ low frequencies dominate ⟹ long, lazy
  travel; low momentum ⟹ twitchy. It is a better control than an accumulator's damping factor
  because it is scale-free.
- **It is also the 1/f drift** the physiology section wants (§10.2): `momentum = 0.5` with
  octave-doubling gives a spectrum near 1/f. One mechanism serves both the dot path and the
  humanisation, which is a genuine simplification.
- **The hash must be explicit and pinned.** Use a small, written-out integer mix (splitmix64-style)
  defined in DAWCore, **not** `Hasher`/`hashValue` — Swift's `Hasher` is seeded per process and
  will produce different values in different runs, which would break reproducibility in the most
  confusing possible way (it looks deterministic in a single test process). §13.1 pins a golden
  vector so a future "optimisation" of the hash reddens a test instead of silently changing every
  project's sound.

⚠️ **Consequence to state plainly: the fBm output is a fixed function of the seed, so it is
reproducible but it is also *not editable*.** A user who likes one bar of a drift and wants to keep
it must commit it and edit the lane (or convert to `.drawn`). That is a real limitation and it is
the reason `.drawn` exists.

### 8.5 The pad's persisted state

```
BreathPadSettings (DAWCore, Codable, Sendable, Equatable)
  ring:        [PatternID]         // 8 by default, order = ring order
  origin:      (angle, radius)     // what the hand set — Wavestation semantics
  path:        DotPath
  seed:        UInt64
  loudnessDepth, biteDepth, sharpenScale, vibratoScale : Double
  tremor:      TremorSettings      // §10.1
  air:         AirBudgetSettings   // §9
  neutral:     Double              // radius-0 effort level
```

**Where does it live?** Recommendation: **on the clip**, as an optional field, not on the track and
not in a global. Reasons: the pad's output is committed *into that clip's lanes*, so co-locating
makes "re-run the pad with a tweak" coherent; it survives copy/paste and duplication with the
clip; and it keeps the store's edit boundary the same one leg D already uses. A track-level default
that new clips inherit can be added later without a migration.

⚠️ **Persisting it is a `Clip` schema addition.** Additive and optional, so old projects decode
unchanged — but it must go through whatever the project's schema-version discipline is, and an
implementing agent must check `Sources/DAWCore/Model.swift` for how other optional clip fields were
added rather than assuming.

---

## 9. The air budget — enforced, and legible

Carried verbatim from the brief:

> **Enforced air budget must be LEGIBLE.** If a phrase goes quiet because the model decided the
> player ran out of air and nothing tells the composer that happened, that is a silent modification
> of composer intent — the exact defect class this session spent the day fixing (seven CC11 lanes
> that were stored, displayed, and completely inert). Whatever you design, "why did this get quiet?"
> must have an answer the composer can see. Design that surface, do not hand-wave it.

### 9.1 The model

Precomputed at prepare time in DAWCore, from note layout alone. **The render path never computes a
budget; it only ever plays back the CC events the budget produced.** That keeps the RT side
arithmetic-only, which it already is.

```
capacitySeconds        : Double   // how long he can play at reference effort
referenceEffort        : Double   // the effort at which capacity is quoted (default 0.6)
consumptionExponent    : Double   // rate = (effort / referenceEffort)^k
refillSecondsPerSecond : Double   // how fast a rest refills
minBreathSeconds       : Double   // a gap shorter than this is not a breath
reserveFraction        : Double   // below this fraction, effort is forced to decay
```

State is a single scalar `air ∈ [0,1]` swept forward across the phrase:

- While a note sounds: `air −= dt · (effort/referenceEffort)^k / capacitySeconds`.
- While resting for at least `minBreathSeconds`: `air += dt · refillSecondsPerSecond`, clamped to 1.
- When `air < reserveFraction`: effort is multiplied by `air / reserveFraction`, so the phrase
  sags into the ground rather than cutting off.

**Sweeping forward is stateful — is that a violation of §5.1?** No, and the distinction matters: the
sweep runs **once, at generation time, over a deterministic note list**, entirely inside DAWCore.
Its result is a function of the clip's notes and the settings, which is exactly the purity the law
requires. It is not evaluated at render time and it carries nothing across calls.

### 9.2 Phrase and breath detection — reuse, do not reinvent

**The tree already has exactly one definition of "a breath" and it must be the one used here.**
`ProjectStore.humanize`'s legato pass (m27-o ⓑ) treats a gap wider than `maxGapBeats` as "a rest —
for a wind part, a breath" (`Sources/DAWCore/ProjectStore+Humanize.swift:112`,
`HumanizeLegato.defaultMaxGapBeats = 0.125` at :63). A phrase is therefore the maximal run of notes
between two such gaps.

Building a second phrase detector would let `humanize` and the pad disagree about where the player
breathes, on the same clip, silently. **Factor the existing gap classification into a shared
DAWCore helper and have both call it.** That refactor is small and it is the difference between one
definition and two.

⚠️ `maxGapBeats` is in **beats** and the air budget is in **seconds**; conversion is through
`TempoMap`, exactly as leg D does (`BreathContour.swift:391-395`). A tempo ramp under a phrase
changes how long the player has been blowing. Do not use a scalar seconds-per-beat.

### 9.3 Defaults, and their provenance

| Setting | Default | Provenance |
|---|---|---|
| `capacitySeconds` | 6.0 | **(estimate)** — the middle of a 4–8 s comfortable-phrase band I did not find a source for. **Exposed precisely because it is unsourced** |
| `referenceEffort` | 0.6 | **(estimate)** |
| `consumptionExponent` | 1.5 | **(estimate)** — superlinear because blowing pressure rises steeply into fortissimo (§2.2's >120 cm H₂O figure, itself abstract-level). Chosen so a full-effort phrase lasts about half as long as a mezzo one |
| `refillSecondsPerSecond` | 0.5 | **(estimate)** — a 2-second rest fully refills |
| `minBreathSeconds` | 0.15 | **(estimate)**, and cross-checked against `defaultMaxGapBeats = 0.125` beats (= 0.25 s at 120 bpm), so the two thresholds are in the same range rather than contradicting |
| `reserveFraction` | 0.25 | **(estimate)** |
| **`enforced`** | **`false`** | **A decision, not an estimate — see §9.5** |

**Every one of these is an estimate.** That is not an apology, it is the design: a model whose
parameters are guesses must expose them, and a model that ships them as hidden constants is a model
that quietly overrides composer intent with a guess. This mirrors leg D's own convention exactly.

### 9.4 THE LEGIBILITY SURFACE (this is the answer to constraint 2)

Four layers. All four are required; any one alone is insufficient.

**Layer 1 — the result type says what happened, per note.** Extending the
`BreathContourApplication` idiom (`ProjectStore+BreathContour.swift:10-33`):

```
AirBudgetReport (Sendable, Equatable)
  phrases: [PhraseReport]
    startBeat, endBeat        : Double
    breathTakenBeforeBeat     : Double?    // nil = no breath available before this phrase
    airAtStart, airAtEnd      : Double     // 0…1
    exhausted                 : Bool       // did air fall below reserveFraction?
    constrainedNotes: [ConstrainedNote]
      noteID                  : UUID
      beat                    : Double
      effortRequested         : Double     // what the pattern asked for
      effortDelivered         : Double     // what the budget allowed
      attenuationDb           : Double     // the honest audible consequence
```

**`effortRequested` alongside `effortDelivered` is the whole point.** "This note is at 0.42" is not
legible. "This note asked for 0.78 and got 0.42, −5.4 dB, because air was at 0.19" is.

**Layer 2 — warnings, in the tree's existing voice.** Plain sentences alongside a *successful*
result, the `MIDIControllerRouting.inertLaneWarning` / media-import idiom. Examples:

- `"the last 6 notes of the phrase at bar 9 were attenuated by up to 5.4 dB because the simulated
  player ran out of air 4.2 s into a 6.8 s phrase — raise air.capacitySeconds, lower the pad
  radius, or set air.enforced=false to turn this off"`
- `"the phrase at bar 17 has no gap longer than 0.15 s before it, so the player never got a breath;
  air carried over at 0.31 of capacity. Insert a rest, or lower air.minBreathSeconds"`
- `"air enforcement changed 23 of 64 notes on this clip"` — **emitted unconditionally whenever the
  budget constrained anything**, so the *existence* of the effect is never silent even if nobody
  reads the detail.

**Layer 3 — the CC lane itself is the visible artefact.** Because the pad commits (§4.2), the
attenuation is *drawn in the piano roll's controller lane*. A composer asking "why did this get
quiet?" can see the curve bend down. This is a structural benefit of choosing (a) over (b) that is
easy to undersell: **under (b) the attenuation would be invisible.**

**Layer 4 — the panel marks the breath points.** The pad UI (P7) draws a breath mark at each
detected breath and shades the region where air fell below `reserveFraction`. Cheap once layer 1
exists, since it is just rendering the report.

**Machine-checked, not asserted:** §13.3 specifies a test that runs the same phrase with
`enforced` true and false and asserts *both* that the CC values differ *and* that the report names
the notes that changed. A pad that attenuates correctly but reports nothing **fails that test**.

### 9.5 Why `enforced` defaults to `false`

The user said the constraint should be enforced, and it is — when the pad is used. But
`air.enforced` still defaults to `false`, for one reason: **an air budget is a model that overrides
what the composer wrote, and a feature that does that must be opted into, once, visibly.** The pad
panel should present it as a prominent, clearly-labelled switch that is easy to find and easy to
turn on — and the MCP tool description should say what it does in one sentence. What must not
happen is an agent calling the pad with defaults and getting a quieter part than it asked for with
no idea why.

If the user prefers `true` by default, that is a one-line change and a legitimate ruling — it is
listed in §17 as an open question for them, not decided here.

### 9.6 The one thing the budget must never do

**It must never make a note silent, and it must never change a note's length or existence.** Effort
is attenuated toward the phrase's floor, never to zero, and the floor is bounded by
`BreathContour.Options.depth` semantics (peak-to-trough travel) — so the worst case is a phrase that
sags, not a phrase that disappears. A model that could delete the end of a phrase because it decided
the player ran out of air would be unshippable regardless of how well it reported it.

---

## 10. Physiological humanisation

### 10.1 Micro-tremor

A held note from a real player is never steady; the effort signal has a small oscillation in
roughly the 4–8 Hz band which deepens as the player pushes harder.

```
tremor(b) = tremorDepth · effort(b)^tremorEffortExponent
          · sin(2π · tremorRateHz · seconds(b) + phase(seed))
```

| Parameter | Default | Provenance |
|---|---|---|
| `tremorRateHz` | 5.5 | **(estimate)** — same band as leg D's `vibratoRateHz` default and deliberately the same number, so the two do not beat against each other in a way nobody chose |
| `tremorDepth` | 0.03 of effort travel | **(estimate)**. Deliberately far below the ~10 % figure measured for *deliberate vibrato* blowing-pressure variation, because tremor is the involuntary residue, not the gesture |
| `tremorEffortExponent` | 1.0 | **(estimate)** — linear growth with effort |

⚠️ **This whole feature is estimated.** I found no measurement of involuntary tremor in wind
performance. What makes it acceptable to ship anyway is that it is (i) small, (ii) parameterised,
(iii) defaulted low, and (iv) **falsifiable** — §13.5 specifies a null test (`tremorDepth = 0`
renders byte-identically to the pre-tremor tree), so if the user dislikes it, it is off by a
number, not by a rebuild.

⚠️ **Tremor and vibrato must not be the same oscillator at the same rate with the same phase**, or
they sum into one deeper vibrato and the "involuntary" character is lost. Give tremor a
seed-derived phase offset and a slightly detuned rate (e.g. `vibratoRateHz × 0.83`, **(estimate)**),
or drive it from the fBm field at a higher octave (§8.4) — the second option is preferable because
it reuses one mechanism and produces a naturally irregular tremor rather than a sine.

### 10.2 1/f drift

Slow, aimless wander in the effort baseline. **This is free**: it is the same `fbm` from §8.4
evaluated at a long scale (default `scaleBeats = 8`, **(estimate)**) with a small amplitude
(default 0.05 of travel, **(estimate)**), added to effort.

⚠️ I found **no** measurement of 1/f structure specifically in wind-instrument breath pressure. 1/f
noise is well established as a general phenomenon
([flicker noise](https://en.wikipedia.org/wiki/Flicker_noise)) and is a conventional choice for
modelling slow human control drift, but **treat "human breath pressure is 1/f" as a modelling
choice this design made, not as a finding**. It is labelled as such in the parameter doc comments.

### 10.3 What NOT to model

- **Onset timing jitter.** `ProjectStore.humanize` already owns note timing and velocity. The pad
  must not also nudge onsets, or two features would fight over the same property with separate
  seeds. **The pad owns effort; humanize owns time and velocity.** Stated as a boundary so an
  implementing agent does not helpfully add it.
- **Note-length variation.** Same reason — that is the legato pass's job (m27-o ⓑ).
- **Growl / flutter tongue.** Above the lane Nyquist (§4.3 item 2). Out of scope for (a) and an
  honest argument *for* (b) if it is ever wanted.

---

## 11. Implementation plan

Ordered so each phase is independently shippable and independently declinable. Every phase ends
with tests green under `./scripts/test.sh` (never bare `swift test`).

### Phase P1 — pattern library and the shape verb (DAWCore only, no engine)

> ✅ **LANDED 2026-08-19.** All three new files and all four edits below exist. Suite
> **6331 tests / 613 suites / 0 ✘ / 6934 ✔** (from 6300 / 612), MCP **417 / 417**, build
> 0 err / 0 warn, wire `allCommands` **182**, MCP tools **187 = 153 wrapper + 34 direct**.
> **Where the build deviates from this plan, the build is what shipped:**
>
> 1. **`peakPosition` is NOT effort-scaled**, although the `BreathContour.swift` row below names
>    it. The pattern already owns `peakPosition`; scaling it by effort as well would give one
>    visible outcome two independent causes, which is the ambiguity §7.2 rejects. The hook
>    (`BreathContour.EffortResponse`) therefore scales `peakValue` and `depth` only.
> 2. **`depth` / `peakPosition` / `onsetLevel` / `releaseLevel` are REFUSED by the wire verb**,
>    not passed through. They *are* the pattern; accepting and ignoring them is the silent-default
>    failure this round exists to end. `clip.applyEffortShape` answers with a teaching error.
> 3. **No CC 1 lane writer was built.** On a hosted-AU track (every `.soundBank`, i.e. the GM sax)
>    bend vibrato aliases in a bounce, so P1 SUPPRESSES it and says so, naming the instrument's own
>    CC 1 vibrato as the route that works. Writing that lane would be a second lane-writing path,
>    which the box below forbids.
> 4. **`applyBreathContour`'s reported `notesWithVibrato` changed** (leg D contract, deliberately):
>    it now requires `vibratoDepthCents > 0` as well as sufficient length, so a contour with
>    vibrato switched off no longer reports vibrato on notes that have none — and the companion
>    "too short" warning no longer fires when vibrato was simply not asked for.
> 5. **`loudnessDepth`/`swellDepth` are inert on a note-scoped pattern** (every note is at effort
>    1, so the response is the identity). Rather than leave that silent, an explicit response on a
>    note-scoped pattern now returns a warning naming the phrase-scoped patterns.
> 6. **Two offline RENDER gates ship with it** (`Tests/DAWEngineTests/SamplerTests.swift`), because
>    promoting `onsetLevel`/`releaseLevel` into `Options` widened the generator's shape family:
>    a phrase hairpin measured +3.72 dB rising note-by-note (per-note peak CC `[75, 82, 101, 119]`,
>    derived rather than remembered: `round(127 × (1 − 0.55 × (1 − blend(0.25, 1, u))))` at
>    u = 0, ¼, ½, ¾), and `sforzandoPiano`'s accent measured 2.10 dB above its settle (against a
>    messaDiVoce control at −0.13 dB). A stored CC ramp is not evidence of an audible one.

**New files**

| Path | Contents |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/EffortPattern.swift` | `EffortPattern` (scope + knots), the 8-entry library, `evaluate(u:)` via `BreathContour.cosineBlend`. Pure, `Sendable`, no store |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/PhraseDetection.swift` | The **factored** gap→breath classifier, extracted from `ProjectStore+Humanize.swift:258-300`, plus `phrases(in:maxGapBeats:)` |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+BreathPad.swift` | `applyEffortShape(clipID:noteIDs:pattern:depth:options:)` — the store boundary. Delegates the actual lane write to leg D |

**Edited files**

| Path | Change |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/ProjectStore+Humanize.swift` | Call the factored classifier instead of its inline gap test. **Behaviour must be byte-identical** — pin with the existing humanize tests before and after |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/BreathContour.swift` | Add an `effortScale` hook so a per-note effort value can scale `depth`/`peakValue`/`peakPosition` without a second contour generator. **Additive, defaulted to the identity** |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift` | Register `clip.applyEffortShape` in `allCommands` and add its handler beside `clip.applyBreathContour` (:297 / :5164) |
| `/Users/dsemenov/Views/daw-pro/mcp-server/src/server.ts` | `clip_apply_effort_shape` |

⚠️ **Do not build a second lane-writing path.** P1's store method computes per-note
`BreathContour.Options` and calls the existing `applyBreathContour` internals. The merge semantics,
point budget, undo step and warnings must be the ones that already exist and are already tested.

### Phase P2 — the circular morph space (DAWCore only)

> ✅ **LANDED 2026-08-19.** Suite **6362 tests / 614 suites / 0 ✘ / 6966 ✔** (from 6331 / 613),
> MCP **421 / 421**, build 0 err / 0 warn, wire `allCommands` **182** (unchanged — no new verb),
> MCP tools **187 = 153 wrapper + 34 direct** (unchanged), plugin mirror re-diffed 0 both ways.
> **Where the build deviates from this plan, the build is what shipped:**
>
> 1. **`neutral` is 1, not §8.2's estimated 0.5.** That estimate was made for a continuous field.
>    The consumer here is `BreathContour.scaled`, where **effort 1 means "exactly as authored"**,
>    so 0.5 at radius 0 would drop the whole part ≈2.8 dB from a control that only says how far
>    out the dot is. It stays a parameter, so P3 can pass 0.5 if its field model wants it.
> 2. **Radius and `amount` are therefore ONE axis and compose as `r × s`**, which this design
>    implies but does not say. Both give `1 + k(raw − 1)`. It is documented in `EffortRing`'s
>    header and pinned by a test at both the pure and the store level, rather than being left to
>    look like two independent controls.
> 3. **P1's single-pattern path was not kept alongside the ring — it BECAME a ring of one.**
>    `applyEffortShape(pattern:)` builds `EffortRing(patterns: [p]).blend(atAngle: 0, radius: 1)`
>    and runs the same body. §13.2's "exact reproduction" is then structural: a render gate
>    measures **0 differing frames of 288000** between naming `messaDiVoce` and parking the dot at
>    45°, against a 67.5° control at 194393.
> 4. **§7.3's law is exposed pointwise (`Blend.level`), and a second, DEFINED object carries it to
>    the store (`Blend.curve`)** — leg D's generator is parameterised, not curve-fed, so the blend
>    must be projected onto `(onsetLevel, peakPosition, releaseLevel, depth)`. The curve's knots are
>    the UNION of its members', which makes a self-blend the identity structurally; mismatched
>    intervals are subdivided 8× because `cosineBlend` is affine in its endpoints only where every
>    member has a knot at both ends. Worst deviation from the pointwise law: **0.0189**, measured
>    (0.132 before the refinement), pinned.
> 5. **⚠️ THE EQUAL-POWER TEST IN §13.2 IS NOT SUFFICIENT AS STATED.** `√w + √(1−w)` is exactly
>    **1.0 at w == 1**, so an equal-power blend reproduces every pattern *perfectly* at every θ_i
>    and is wrong only between them. A self-blend sweep aligned to the pattern angles ships the bug
>    green. Every sweep in `EffortRingTests` includes the midpoints, and one test names the 1.414
>    figure explicitly with a positive control that it really does differ.
> 6. **The rendered discriminator is a comparison of two RENDERS, not a derived dB.** The hairpin
>    midpoint blends to a constant 0.625 ⇒ peak CC 101 (equal-power: 119); rendered, it sits
>    **−0.0007 dB** from a CC-101 reference and **−1.425 dB** from the CC-119 one. ⚠️ **−1.425, not
>    the −2.85 a square law predicts: on the BUILT-IN sampler CC 11 is closer to linear.** The
>    measured square law belongs to the hosted-AU path (§1.2) and does not transfer.
> 7. **`clip.getEffortField` was NOT built** (§12 recommends it). It would be a new verb, and the
>    ring needed none — `allCommands` stays 182.
> 8. **`pattern` had to become optional in the zod schema**, so a call with neither form moved from
>    a client-side refusal to an app-side teaching error. `registerTool` wraps a raw shape in
>    `.strict()`, so there is no `.refine()` seam for "exactly one of". Recorded in
>    `mcp-server/test/clip-apply-effort-shape.test.ts` so the move is visible rather than looking
>    like a lost assertion.

**New file:** `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/EffortRing.swift` — the ring, the
nearest-two weight law (§8.2), the blend law (§7.3). Pure.
**Wire:** extend `clip.applyEffortShape` with `ringAngle` / `ringRadius` / `ring` parameters
(additive; the single-pattern form stays valid).

### Phase P3 — dot paths (DAWCore only)

> ✅ **LANDED 2026-08-19.** Suite **6389 tests / 615 suites / 0 ✘ / 6994 ✔** (from 6362 / 614),
> MCP **424 / 424** (from 421), build 0 err / 0 warn, wire `allCommands` **182** (unchanged — no
> new verb), MCP tools **187** (unchanged), Copilot catalog **77** (unchanged), plugin mirror
> regenerated and diffed 0 both ways.
> **Where the build deviates from this plan, the build is what shipped:**
>
> 1. ⛔ **§8.4 CONTRADICTS ITSELF ABOUT `momentum`, and the prose won.** The formula
>    `Σ m^j · noise(x·2^j)` makes `m` the amplitude of the *faster* octaves, so raising it makes
>    the path **twitchier** — the exact opposite of the same section's "high momentum ⟹ long, lazy
>    travel". The user's words ("flow from one pattern to the other") and any defensible UI knob
>    both need the prose reading, so `persistence = 1 − momentum`, inverted **once**, visibly, at
>    `DotPath.drift`. ⭐ The map is a reflection about 0.5, so §10.2's one numeric claim
>    ("momentum 0.5 ⇒ ≈1/f", which P5 reuses) comes out at the **same number** either way.
> 2. ⛔ **§8.4's literal `seed ⊕ j` octave derivation makes adjacent seeds share an octave** —
>    seed 4's octave 1 is `4 ⊕ 1 = 5`, which is seed 5's octave 0 at twice the rate. `derivedSeed`
>    hashes the domain index instead. ⚠️ And the obvious instrument is blind to this: the max of
>    |Pearson r| over ±64 lags runs **0.45 for both** derivations (measured, 40 pairs each),
>    because it is dominated by the smoothness of the signal. §13.1's seed test is therefore
>    **distributional** (12 adjacent pairs against 12 distant), and the octave sharing has its own
>    direct test with a positive control that reproduces it.
> 3. **The field is evaluated at CLIP-RELATIVE beats, and the dot is sampled ONCE PER NOTE** at
>    the note's start. Both are decisions with consequences and both are in the file's header:
>    clip-relative makes §8.4's loop-cycle invariance *structural* (the lane is clip data and the
>    unroller copies it — a timeline-relative field would promise per-cycle variation the write
>    path cannot deliver), and per-note sampling makes the **note grid**, not the render block
>    rate, P3's resolution limit. §13.1's "loop cycle 1 == cycle 5" is consequently vacuous as
>    written; the discriminating store-level form is **clip-position invariance** (move the clip,
>    get the identical lane), paired with a field-level test that the field really is
>    position-sensitive — without which the first would pass on a constant.
>    ⚠️ A `loopCycleInvariance` test WAS written against the design's wording and then **deleted**,
>    not left green: clip-relative reduces it to `dot(atBeat: b) == dot(atBeat: b)`, the same
>    expression twice, which nothing short of a wall-clock read between two statements could fail.
>    A test that cannot fail while wearing the name of the property it guards is worse than no
>    test — the next reader counts it as coverage. `BreathPadDeterminismTests` records the absence
>    and where the property is actually carried.
> 4. ⚠️ **Judging aliasing by the literal top octave fires on the recommended defaults**: at
>    persistence 0.5 with 4 octaves the top one carries **6.7 %** of the amplitude. The warning
>    uses the highest octave at ≥ 20 % (`audibleOctaveShare`) and compares it to the **note rate**
>    rather than to Nyquist — above Nyquist you lose detail, above the note rate you are certainly
>    hearing an alias. Similarly, "the wander only touched one pattern" is the wrong test for
>    inertness (a 2° wander around a dot parked exactly on a pattern straddles the boundary and
>    touches two, at weights of thousandths); the test is travel against ring spacing.
> 5. **`.drawn` and `.musical` were NOT built.** `.drawn` has no producer until P7's drag exists,
>    and fixing its knot format now would pin a wire shape for a caller that is not written.
>    `.musical`'s musical rule is unspecified in this design, and inventing it here would ship an
>    estimate as a mechanism.
> 6. **`effort(atBeat:settings:phrase:note:)` has no production caller.** The store shapes notes
>    through `EffortField.blend(atBeat:)` and leg D's parameterised generator, for the reason §11's
>    P2 note 4 already gives. It is built, public and tested because the design names it as the
>    field law and P4's air sweep is its consumer.
> 7. ⚠️ **`pathSeed` is capped at 2³²−1 on the wire**, and the cap is not tidiness: a JSON number
>    is an IEEE double, so a seed above 2⁵³ would arrive as a *different* seed and "same seed, same
>    performance" would stop being true for large values only — silently.
> 8. ⚠️ **§12's "unknown keys are silently stripped" is not what this SDK version does.** Measured
>    by deleting `momentum` from the zod schema and re-running: the call is **refused
>    client-side** (`isError`), never reaching the bridge, because `registerTool` wraps the raw
>    shape in `.strict()`. Either way the whole-frame test catches it — it was run against the
>    deleted key and failed — but the failure to expect is a refusal, not a missing key.

**New file:** `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/EffortField.swift` — `DotPath`, the
pinned `splitmix64`-style hash, `smoothNoise`, `fbm`, and the top-level
`effort(atBeat:settings:phrase:note:)`. **This file is where THE PAD LAW (§5.1) lives and it must
carry the law in its doc comment**, leg-D style.

### Phase P4 — the air budget (DAWCore only)

> ✅ **LANDED 2026-08-19.** Suite **6423 tests / 616 suites / 0 ✘ / 7029 ✔** (from 6388 / 615),
> MCP **427 / 427** (from 424), build 0 err / 0 warn (both greps positive-controlled by planting
> one of each), wire `allCommands` **182** (unchanged — no new verb; counted 182 with a
> harvester positive-controlled to return 183 on a planted entry, and the tree's 19 pins are
> green), MCP tools **187** (unchanged), Copilot catalog **77** (unchanged), plugin mirror
> regenerated and diffed on all six keys with a negative control.
> **Where the build deviates from this plan, the build is what shipped:**
>
> 1. ⛔ **§9.1's `referenceEffort` WAS NOT BUILT, and the reason is algebra.** The design's
>    rate `(effort/referenceEffort)^k / capacitySeconds` expands to
>    `effort^k / (referenceEffort^k · capacitySeconds)` — `referenceEffort` and
>    `capacitySeconds` are provably ONE axis and only their product is observable. Shipping
>    both is the `ringRadius`-vs-`amount` trap P2 documented, one visible outcome with two
>    controls. ⭐ It also closes a **units mismatch that would otherwise have shipped**:
>    `effort` here is `BreathContour.scaled`'s REDUCTION FACTOR, where 1 means "exactly as
>    authored", *not* an absolute pressure. Feeding 1 into `(e/0.6)^1.5` reads every unshaped
>    note as fortissimo and burns air **2.15× faster than the quoted capacity** — the reserve
>    would be crossed at 2.09 s where the number says 4.5 s. `capacitySeconds` is therefore
>    quoted at the as-authored level and the rate is `effort^k / capacitySeconds`.
> 2. **§9.4's `breathTakenBeforeBeat: Double?` became a three-case `Breath` enum**
>    (`.none` / `.taken` / `.tooShort`). `nil` conflated "first phrase, nothing before it"
>    with "there was a gap and it was too short to breathe in" — two situations with opposite
>    fixes, which is exactly the one-symptom-two-causes ambiguity §9 forbids elsewhere.
> 3. **`effortDelivered` is `effortAllowed`, and the report carries `applied`.** The sweep
>    feeds ALLOWED effort back into consumption (a player running short blows softer and lasts
>    longer), so the report is the ENFORCED trajectory in both modes and is IDENTICAL either
>    way — `enforced` decides only whether the lane changes. That makes "what would this do?"
>    answerable without mutating a project, and it makes §13.3's test sharper (same report,
>    different CC). But with `enforced` false the numbers are a **counterfactual**, and a field
>    named `effortDelivered` would have asserted a delivery that never happened.
> 4. ⛔ **§9.6 HAD A REACHABLE HOLE, and it was reachable ONLY in P4.** The wire accepts
>    `loudnessDepth: 1`, and `BreathContour.scaled` computes `peak × (1 − L(1−e))`, which is
>    exactly **0** at `L = 1, e = 0` — a written lane that MUTES the note. Before enforcement
>    existed, effort was pinned at 1 wherever the response was live, so the shortfall term was
>    always 0. `AirBudget.minimumEffort(peakValue:response:)` binary-searches the floor against
>    `scaled` itself (never a re-derived inverse) and the sweep applies it per note; both
>    halves of §9.6 (never silent, never changes length or existence) have tests.
> 5. **The sweep runs over the WHOLE clip, not the selection.** A player who has been blowing
>    since bar 1 does not arrive at bar 9 with a full lungful because the caller selected only
>    bar 9. Unselected notes consume at their authored level and can be reported short of air
>    with `shaped: false`; a warning names the count rather than letting them pass as a change
>    that happened.
> 6. ⚠️ **The P1 inert-response warning REVERSES under enforcement and had to be re-gated.**
>    With air pulling effort below 1 on a note-scoped pattern, `loudnessDepth`/`swellDepth` are
>    exactly what makes the sag audible, so "they did NOTHING" becomes false and would send the
>    caller to delete the parameters carrying the effect. Both directions are tested.
> 7. **Wire keys are flat and `air`-prefixed** (`airEnforced`, `airCapacitySeconds`, …), not
>    §9.4's dotted `air.capacitySeconds`, and every warning names the key that actually exists.
>    ⚠️ `airBudget` was avoided as a key name **on purpose**: P3's parity gate uses
>    `properties["airBudget"] == nil` as its positive control, and naming a real key that would
>    have silently killed the control.
> 8. ⭐ **MEASURED, and the number belongs in this document.** On a realistic 16-bar 4/4 part at
>    120 bpm phrased in two-bar groups with one beat of rest between them: at the as-authored
>    level the defaults constrain **34 of 56 notes**, exhaust **7 of 8** phrases and set
>    `neverRecovered`; at a mezzo dynamic they constrain **0**. That is the model working (3.5 s
>    of blowing costs 0.58 of a lungful and a 0.25 s rest returns 0.125), but it is aggressive,
>    and the estimate it puts most pressure on is `refillSecondsPerSecond`, not
>    `capacitySeconds`. Recorded rather than silently retuned.
> 9. **RENDER GATE (16 notes, defaults, `messaDiVoce`):** the six notes the report calls short
>    of air render **−1.62 dB (mildest) to −4.76 dB (worst)** below every well-supplied note,
>    with **0 inversions** against the stored per-note peak CC `[127×10, 104, 91, 83, 78, 74,
>    71]`. Controls: `enforced: false` renders **0 differing frames of 432000** against never
>    mentioning air, the unenforced render is flat to **0.00024 dB**, and enforcement differs on
>    146320 frames. A phrase the player can AFFORD renders **bit-identically** with enforcement
>    on — the null that stops the budget being a blanket attenuator.
>    ⚠️ −4.76 dB where the square law predicts −10.1: on the BUILT-IN sampler CC 11 is closer
>    to linear (P2 measured the same), so the report's `attenuationDb` is the CONSERVATIVE
>    hosted-AU reading and the exact `peakCCRequested`/`peakCCAllowed` integers ship beside it.
> 10. **"Air runs out" was already absent from `EffortPattern.library`** (P1 omitted it with a
>    comment). P4 adds the regression guard — and the guard's first form was WRONG:
>    `text.contains("air")` matches **h-air-pinCrescendo** and fired on the shipped library.
>    It is token-based now, with the hairpin case pinned.
> 11. ⛔⛔ **THE WARNING WRITTEN TO PREVENT THE DEFECT COMMITTED IT.** The §9.4 layer-2 summary
>    was gated on `applied` alone. Enforcement ON with `noteIds` naming only well-supplied
>    notes gives `constrainedShapedCount == 0` and `constrainedNoteCount > 0`, so it read
>    *"air enforcement changed 0 of 2 shaped notes … pulled down by up to 13.9 dB"* — a dB
>    figure quoted about notes this call never wrote, in the past tense, about a lane
>    byte-identical to `airEnforced: false`. Every claim of a change is now gated on
>    `wrote = applied && constrainedShapedCount > 0`, every quoted figure is measured over the
>    notes its own sentence is about, and the zero case gets its own sentence ("air enforcement
>    is ON but changed NOTHING this call wrote"). The counterfactual dB may still appear, but
>    only ever carrying "would be". Gated by
>    `enforcementThatWritesNothingClaimsNothing`, whose negative control (revert to `applied`)
>    turns it red with 3 issues.
> 12. ⛔ **FOUR AIR SENTENCES LEAKED TO CALLERS WHO NEVER MENTIONED AIR.** `worst`, `starved`,
>    `neverRecovered` and `unshaped` sat outside the `applied || airAsked` fork, so a plain
>    `applyEffortShape(clipID:pattern:)` on any part with more than ~4.5 s of sounding time
>    started answering with *"in the worst phrase, the last 5 notes would be attenuated…"* — a
>    behaviour change to a live verb, and the opposite of what the function's own doc comment
>    claimed. The whole function is now gated. The test that should have caught it asserted
>    `!contains("air enforcement is OFF")`, which none of the leaked sentences contain; it now
>    asserts that **no warning mentions air at all**, tokenised (the h-air-pin lesson again) and
>    positive-controlled in both directions.
> 13. ⚠️ **A CONSTRAINED NOTE CAN COST 0.0 dB, AND IS LISTED ANYWAY.** The report filters on the
>    MODEL's `effortAllowed < effortRequested`; the lane is CC integers, and one step at peak
>    127 / `loudnessDepth` 0.55 is Δeffort ≈ 0.0143. A note starting a hair below the reserve
>    therefore ships with both CC integers equal. It is reachable — found by sweeping
>    `capacitySeconds`, and it lands exactly where the arithmetic says (`capacitySeconds`
>    7.981 puts the beat-12 note on 0.2482 of a lungful) — and it is pinned by
>    `aNoteConstrainedByLessThanOneCCStepIsStillNamed`. **Listed on purpose:** filtering on the
>    audible change would drop notes the budget touched and would empty the report entirely
>    under an identity response, the one case where the caller most needs to hear that
>    enforcement did something inaudible. The wire test previously asserted
>    `peakCCAllowed < peakCCRequested` for **every** listed note and was green by fixture luck;
>    it now asserts `<=` per note plus one strictly-less across the list.
> 14. ⛔⛔ **THE BUDGET WAS LEAKING INTO P1's "IT RAN AND DID NOTHING" SIGNAL.**
>    `minEffort`/`maxEffort` were briefly built from the WRITTEN effort. MEASURED: on a
>    note-scoped pattern, where every gesture asks for effort 1 and the P1 invariant is
>    `min == max == 1`, enforcement turned it into **`4.4e-16 … 1.0`** — and the wire comment,
>    the MCP tool description and the Copilot catalog all promise, in the same words, that
>    *equal values mean the shape ran and varied nothing*. Three caller-facing surfaces would
>    have read the budget's work as variation the gesture never asked for: one symptom, two
>    causes, in the one field that exists to be unambiguous. They are the REQUESTED range again;
>    the budget's effect on the lane lives in `air.constrainedNotes`, per note, with
>    `effortRequested` beside `effortAllowed`. Pinned by
>    `enforcementDoesNotDisturbTheEffortRange` (fixture-checked to prove enforcement really did
>    change that lane), negative control = build them from `writtenEffort` → red.

**New file:** `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/AirBudget.swift` — the sweep,
`AirBudgetSettings`, `AirBudgetReport`.
**Edited:** `ProjectStore+BreathPad.swift` folds the report into its result and emits the §9.4
layer-2 warnings.

### Phase P5 — humanisation

> ✅ **LANDED 2026-08-19.** No new files, as planned. Suite **6423 → 6448 / 616 suites**
> (unchanged — every test folded into an existing suite), MCP **427 → 430**, build
> 0 err / 0 warn, wire `allCommands` **182** (unchanged — no new verb), plugin mirror
> re-diffed on all six keys with a positive and a negative control.
> **Where the build deviates from this plan, the build is what shipped:**
>
> 1. ⛔⛔ **§10.1's 4–8 Hz band is UNREACHABLE ON THE HOSTED-AU PATH — the WHOLE band,
>    not just its top — and P5 MEASURED the half that had only been derived.** §2.3a of
>    `measure-gm-sax-cc.md` measured the block sample-and-hold for **pitch bend**; the
>    obvious escape from it is to deliver tremor amplitude-side on CC 11, so P5 measured
>    that (`SoundBankHostingTests` T5, stock GM alto sax through AUSampler). There is no
>    escape. The image/commanded ratio obeys the zero-order-hold closed form
>    **`f / (f_s − f)`** at four measured rates within 3 %:
>
>    | f | image at | measured | `f/(f_s−f)` |
>    |---|---|---|---|
>    | 2.0 Hz | 9.719 Hz | 0.222 | 0.206 |
>    | 4.0 Hz | 7.719 Hz | 0.520 | 0.518 |
>    | 5.5 Hz | 6.219 Hz | 0.911 | 0.884 |
>    | 8.0 Hz | 3.719 Hz | **2.139** | 2.151 |
>    | 8.0 Hz, built-in `.sampler` | — | **0.043** | (no quantiser) |
>    | no lane at all (floor) | — | 400× below | |
>
>    At the band's **bottom** the image is already 52 % of the tremor; at 8 Hz it is the
>    louder of the two and the tremor arrives at 3.72 Hz. Holding the image 12 dB down
>    needs a rate ≤ **2.34 Hz**, below the band a tremor *is* — so the tremor is
>    **SUPPRESSED** on `.soundBank`/`.audioUnit` tracks, as P1 suppresses bend vibrato,
>    with a warning naming **our own `OfflineRenderer` 4096-frame block** as the cause
>    rather than the plugin (§2.4 predicts live playback at 512 frames is clean). The
>    drift is unaffected: it is three orders of magnitude below the ceiling.
> 2. ⛔ **`tremorDepth` is a fraction of the CONTOUR LEVEL, not of §10.1's "effort
>    travel", because the plain reading is INAUDIBLE.** Travel is `peakValue × depth` =
>    31.75 CC at leg D's defaults, so 0.03 of it is **±0.95 CC — one integer step**,
>    measured at **0.16 dB peak-to-trough** (T6; the line is 0.0755 dB per CC of
>    peak-to-trough travel, measured at ±1, ±2, ±4 and ±8). Against the level, 0.03 is
>    3.81 CC ⇒ ≈ 0.29 dB. The feature would have shipped inert at its own default.
> 3. ⛔ **The tremor rides the CONTOUR, not `effort`.** §10.1 adds it to effort, but
>    effort reaches the lane only through `BreathContour.EffortResponse.loudnessDepth`,
>    whose default is the identity — so a tremor added to effort is inert at the default
>    response. That is P1's finding 5 arriving a second time.
> 4. ⭐ **Both defaults are 0, not §10.1/§10.2's 0.03/0.05, because §10 contradicts
>    §13.5.** §13.5 requires the rendered bytes at the default to match the pre-feature
>    tree; a non-zero default cannot do that. §13.5 wins and §10's numbers ship as the
>    *suggested* values in the doc comments, each carrying its measured dB.
> 5. ⚠️ **§10.1's preferred fBm-driven tremor was EVALUATED AND REJECTED.** fBm puts
>    energy at 2× and 4× the base rate, which is exactly where the ceiling bites hardest
>    (an octave at 9.13 Hz returns at 2.59 Hz *louder* than it went in), and it leaves
>    the tremor with no single rate to check a ceiling against.
> 6. ⭐ **BOTH involuntary layers are DOWNWARD-ONLY, and that is a rectification fix.**
>    `BreathContour.scaled` clamps effort to 0…1 and a note-scoped pattern sits at
>    exactly 1, so a symmetric drift would be half-rectified there; the contour peaks at
>    `peakValue` = 127, the top of the lane, so a symmetric ripple would clamp on the
>    loudest instant of every note. Both would ship a lowered mean under the name of an
>    oscillation, invisible to any "did the samples change?" test.
> 7. ⚠️ **A SECOND ceiling was found, and it is OURS: 6.25 Hz.** The expression grid is
>    50 Hz and this file's own `minPointsPerVibratoCycle` is 8. Rather than warn about
>    it, `generate` refines the grid when the tremor is on — so the only ceiling left is
>    the hosted-AU one and the warning cannot be blamed on the wrong cause. The bend
>    lane deliberately keeps the *unrefined* spacing, so a knob about loudness cannot
>    move the vibrato's budget.
> 8. ⚠️ **The drift lands in `minEffort`/`maxEffort`; the air budget still does not.**
>    Opposite of P4's placement, on purpose: those two fields promise "the shape ran and
>    varied nothing", the budget is a *constraint* on the gesture, and the drift *is*
>    gesture. P1's inert-response warning gains a third clause and reverses again, the
>    same shape P4's air clause has.
> 9. ⭐ **A PLANTED REGRESSION FOUND A REAL DEFECT IN THE BUILD.** The ripple formula
>    existed **twice** — `EffortField.tremorRipple` and a local copy in
>    `BreathContour.generate` — so a plant that made the *generator's* copy symmetric
>    left the pure test green: coverage that was not covering the shipping arithmetic.
>    Collapsed to one implementation (`rateHz` is a plain parameter now) and re-planted;
>    both tests then failed.
>
> 10. ⛔⛔ **A REVIEW PASS FOUND A DEFECT ALL OF THE ABOVE MISSED: `tremorRateHz` WAS
>    CLAMPED TWICE, TO DIFFERENT BANDS.** `EffortField.Humanisation.sanitized()` took
>    0.01–40; `BreathContour.Options.sanitized()` took 0.2–20, inherited from the vibrato
>    band. `ProjectStore` derives each note's tremor **phase** from the first and the
>    generator **oscillates** at the second, and all three wire surfaces advertised the
>    wider band — so `tremorRateHz: 25` was reachable and advanced the phase at 25 Hz
>    while the waveform ran at 20 Hz, planting a growing discontinuity at every note
>    onset while every surface reported a value that was "in range" on its own terms.
>    The discriminating test was written first and failed on **7 of 13** wire-legal
>    rates. The fix is one band declared once —
>    `EffortField.Humanisation.minTremorRateHz`/`.maxTremorRateHz` — referenced by both
>    sanitizers, `Commands.swift` and the catalog, with zod at `.min(0.2).max(20)`. The
>    band is the vibrato band because its reasoning transfers: **below 0.2 Hz a "tremor"
>    is a drift**, which is a different knob on this same struct. Out-of-band is
>    **rejected, not clamped** — clamping would hand back a different gesture under the
>    name the caller asked for, which is the failure mode this whole phase exists to
>    avoid. The 2.34 Hz hosted-AU ceiling sits comfortably inside the band.
> 11. ⛔⛔ **THE COPILOT CATALOG'S PARAM KEYS WERE UNGATED, MEASURED NOT SUPPOSED.**
>    Planting `tremorRateHZ` in `CopilotCatalog.swift` left the entire `Copilot`-filtered
>    run — 238 tests, 20 suites — **green**. `CopilotCatalogTests` pins command names,
>    schema shape and entry count, and never inspects a property key, so a typo there
>    advertised a parameter the wire refuses and the only symptom is a plausible error
>    blamed on the model. `catalogParamKeysAreAcceptedByTheWire` now scrapes the
>    `rejectUnknownKeys([...], verb:)` array literals from `Commands.swift` and asserts
>    **catalog ⊆ wire** — a curated subset is legal, a typo is not — with a positive
>    control on the scrape and a `checked >= 50` guard so it cannot pass vacuously. It
>    reddens under the re-planted typo and is green across all 77 catalog entries
>    (its reach is printed: 77 of 77, against 182 scraped wire key sets).
> 12. ⛔⛔ **THE `Commands.swift` PARSE → STORE FORWARD WAS UNTESTED, AND NO P5 GATE COULD
>    HAVE SEEN IT.** Store tests call `ProjectStore.applyEffortShape` directly and never
>    enter `Commands.swift`; MCP tests stop at a mocked bridge; the catalog gate checks
>    spelling, not use; and `rejectUnknownKeys` proves a key is not *refused*, which is
>    not that it is *applied*. MEASURED twice: deleting the `humanisation:` forward from
>    the **ring-form** call (it compiles — the parameter defaults to `.none`) left
>    `DAWControlTests` green at **1036 tests / 92 suites**; misspelling the PARSE key
>    `"tremorRateHZ"` left the same 1036/92 green. Accepted-but-ignored — the call
>    succeeds, the response looks right, the default is silently used.
>    `humanisationKeysReachTheStoreOnBothForms` now drives the verb through
>    `CommandRouter` **once per form**, because two forwards are two ways to be
>    half-wired and the ring form is the one a pattern-only test never reaches. Its
>    sharpest assertion is that **1 Hz and 5 Hz must produce different lanes**: a dead
>    RATE is invisible while a live DEPTH still moves the lane, and plant 7 fires that
>    assertion and only that one.
>
> **Gates:** 12 pure tests in `BreathPadDeterminismTests`, 6 store tests in
> `ControllerLaneStoreTests`, 2 render gates in `SamplerTests`, 2 measurement gates in
> `SoundBankHostingTests`, 1 wire-parity gate in `CopilotCatalogTests`, 2 parse→store
> wire gates in `ControllerLaneCommandTests`, 3 MCP round-trip tests. **RENDER: `.none` vs never-mentioning-it
> = 0 differing frames of 240 000, and rates-without-depth = 0; `tremorDepth: 0.12` =
> 194 387 differing frames, `driftDepth: 0.4` = 239 983.** Audibility: the 5 Hz envelope
> bin is 113.9× the un-tremored render, and the 9 Hz bin on the same render is 292× below
> it, so the energy is *at* the commanded rate rather than broadband.
> **All SEVEN planted regressions reddened**, and the null passed under the
> wired-to-nothing plant — which is precisely why the null alone is not evidence.

Small additions to `EffortField.swift` (tremor, drift). No new files. **Every knob defaults to a
value that reproduces P4's output exactly**, so the null test in §13.5 is meaningful.

### Phase P6 — the live preview (the only DAWEngine work)

| Path | Change |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/InstrumentSourceNode.swift` | **Amend the contract** at :341-353 and :731-743 to bless controller payloads on the audition ring (§5.3 step 1); add `pushAuditionController(controller:value:)` |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWCore/EngineProtocol.swift` | Add `func previewController(trackID:controller:value:) -> AuditionOutcome` to `AudioEngineControlling` **with a `.unsupported` default**, exactly mirroring `setAuditionPitches` (:997-1013) |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/AudioEngine.swift` | Implement it: resolve the track's node, apply the 30 Hz coalescing cap, push |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWControl/Commands.swift` | `pad.previewEffort` (gesture-scoped; see §12) |

⚠️ **THE PROTOCOL NAME IN `CLAUDE.md` IS WRONG AND AN IMPLEMENTING AGENT WILL LOSE TIME TO IT.**
`CLAUDE.md` and `docs/ARCHITECTURE.md` speak of `AudioEngineProtocol`. **The actual protocol is
`AudioEngineControlling`**, declared at `Sources/DAWCore/EngineProtocol.swift:343-344`, with ~20
conformers across `Sources/` and `Tests/`. Grepping for `AudioEngineProtocol` returns essentially
nothing and looks like "the seam does not exist". (The invariant itself is intact and this design
preserves it: DAWCore declares, DAWEngine implements, no CoreAudio type crosses.)

⚠️ **A `.unsupported`/no-op default is a vacuity risk and the tree says so out loud** — see the
warning on `availableOutputDevices` at `EngineProtocol.swift` about a real engine that "forgot to
override this" while "every test would still pass". P6 must ship the equivalent of
`OutputDeviceTests`: a test that asserts the **real** `AudioEngine` does not return `.unsupported`
for a track that has an instrument node.

### Phase P7 — the panel

| Path | Contents |
|---|---|
| `/Users/dsemenov/Views/daw-pro/Sources/DAWAppKit/BreathPadModel.swift` | Headless-testable model: dot state, drag handling, hit-testing, preview throttling, commit trigger. **All the logic lives here**, following `HumanizeModel` / `QuantizeModel` |
| `/Users/dsemenov/Views/daw-pro/Sources/DAWApp/BreathPad/BreathPadView.swift` | Canvas: the ring, pattern labels, the dot, the trail, breath marks, the air gauge. `docs/DESIGN-LANGUAGE.md` — dark glass, neon glow, beginner-readable labels |

⚠️ `Sources/DAWApp/DAWProApp.swift` is ~10.4k lines and `ProjectStore.swift` ~7.4k. Background
agents in this repo have died to a 600 s liveness watchdog reading them whole. **Grep first, read
narrow ranges, one agent at a time.**

### Suggested routing

| Phase | Agent |
|---|---|
| P1–P5 | `audio-dsp-engineer` (the curve/noise maths) with `swift-app-engineer` for the store boundary |
| P6 | `audio-dsp-engineer` — it is the only RT-adjacent leg and the contract amendment needs RT-safety judgement |
| P7 | `ui-design-engineer` |
| Wire + MCP | `mcp-integration-engineer` |
| Tests | `qa-test-engineer`, but §13's discriminating tests should be **specified by whoever wrote the phase**, not invented downstream |

---

## 12. Wire and MCP surface

Additive only. **No live command is renamed.** `clip.applyBreathContour` keeps its exact current
contract.

| Verb | Params | Notes |
|---|---|---|
| `clip.applyEffortShape` | `clipId`, `noteIds?`, `pattern?`, `ring?`, `ringAngle?`, `ringRadius?`, `path?`, `seed?`, `air?`, `tremor?`, plus the leg-D option passthrough | The one composing verb. Returns the leg-D result fields **plus** `airReport` and `warnings` |
| `clip.getEffortField` | `clipId`, `fromBeat`, `toBeat`, `resolutionBeats` | **Read-only preview of the curve without writing anything.** This is what lets an agent (or a test) check the model's output without mutating a project. Strongly recommended — it is the cheapest possible answer to "did it actually do something?" |
| `pad.listPatterns` | — | Names, scopes, descriptions. Discovery |
| `pad.previewEffort` | `trackId`, `value` (0…1), `gesture` (`begin`/`move`/`end`) | Gesture-scoped so the "never streams without a gesture" rule (§5.2) is enforced **on the wire**, not only in the UI. `end` stops streaming |

⚠️ **`mcp-server/` zod schemas are closed `z.object()` with no `.passthrough()`** — verified: the
only occurrence of the word "passthrough" in `server.ts` is inside a comment at :7576, so there is
no `.passthrough()` anywhere. **Unknown keys are silently stripped**, which already produced a real
defect. Consequences for this plan:

1. Every new parameter must be added to the tool's zod object in the same change that adds it to the
   Swift verb. A parameter added on one side only fails **silently**.
2. The Swift side must keep using `params.rejectUnknownKeys([...], verb:)` and the
   `boundedOption` / `boundedIntOption` teaching-error helpers, so a bad value is refused with a
   sentence rather than clamped (the pattern established at `Commands.swift:5188-5233`).
3. A test must assert the zod key set equals the Swift `rejectUnknownKeys` list for each new verb.
   This is the only mechanical defence against the two drifting.

⚠️ **Wire and MCP totals**: `docs/ARCHITECTURE.md`'s dated *"Wire surface — CURRENT TOTALS"* table
is the authority, not the prose headline elsewhere in that file (which has rotted four times).
Re-measure at close; do not add one to a remembered number.

---

## 13. What I would test, and what would prove it works

This tree's characteristic failure is *"returns something that looks like a valid answer"* — seven
CC11 lanes that were stored, displayed, and completely inert. **A test that asserts "the lane has
points" would have passed on all seven of them.** Every test below is chosen to fail on that.

### 13.0 The rule the whole section follows

> **Assert on RENDERED AUDIO, or on a value the render path actually consumed. Never on the
> existence of authored data.** Where a test must assert on data, it must be paired with a
> **negative control** that changes one input and asserts the output changes.

### 13.1 Determinism — both halves, or it proves nothing

`Tests/DAWCoreTests/BreathPadDeterminismTests.swift`

1. **Positive:** `EffortField.effort(atBeat:)` sampled at 2000 beats, twice, in two freshly
   constructed instances → **bit-identical `Double`s** (compare bit patterns, not `==` with an
   epsilon).
2. **Negative control:** same call with `seed + 1` → **assert the samples DIFFER**, at more than a
   trivial number of points. *This is the half that catches a seed which is threaded but never
   read*, which is the exact shape of today's inert-CC11 defect.
3. **Seek invariance (this is what kills the accumulating random walk, §8.4):** evaluate beat 512
   cold, then evaluate 0…512 sequentially and take the last value → **must be identical.** An
   integrating implementation fails this and nothing else in the suite would catch it.
4. **Golden hash vector:** pin `splitmix64(seed: 1, k: 0…7)` to eight literal `UInt64`s. A future
   "optimisation" of the hash then reddens a test instead of silently re-voicing every project.
   **Must not use Swift's `Hasher`** — it is per-process seeded.
5. **Offline render equality:** render the same clip twice through `OfflineRenderer` → byte-identical
   output. Then change only the seed → **assert the bytes differ.**

### 13.2 The blend law

`Tests/DAWCoreTests/EffortRingTests.swift`

- **Partition of unity:** sweep φ over [0, 2π) in 1000 steps; `Σ w_i == 1` within 1e-12 at every step.
- **Exact reproduction:** at `φ = θ_i, r = 1`, the blended curve equals `pattern_i` **at every
  sample**, not just at knots. This is the property inverse-distance weighting would fail (§8.2).
- **Identity under self-blend:** a ring of 8 copies of one pattern produces that pattern at every φ.
  This is what catches an accidental equal-power (`sqrt`) blend, which would return it at ≈1.414× (§7.3).
- **Wrap continuity:** `effort` at `φ = 2π − ε` and `φ = 0 + ε` differ by O(ε).
- **Mixed-scope blending:** a `.note`-scoped and a `.phrase`-scoped pattern blended over a clip whose
  notes have unequal lengths → finite, in range, and continuous. This is the "different lengths"
  case §7.3 claims is a non-issue; assert it rather than claiming it.

### 13.3 The air budget — the constraint-2 test

`Tests/DAWCoreTests/AirBudgetTests.swift`

**One test, three assertions, all required:**

```
same 12-note phrase, ~8 s at effort 0.85, capacity 6 s
run A: air.enforced = false
run B: air.enforced = true

1. the CC 11 lanes DIFFER, and B's values are strictly lower in the last third   ← it did something
2. B's report names ≥1 constrained note, with effortRequested > effortDelivered  ← it said so
3. B's warnings array contains a sentence naming the phrase and the dB figure     ← a human can read it
```

**Assertion 2 is the one that makes this a constraint-2 test.** A pad that attenuates correctly and
reports nothing passes 1 and 3-minus and still fails the requirement. Also assert the converse:
a phrase *within* budget produces an **empty** `constrainedNotes` and **no** air warning — otherwise
the report is decoration that always fires.

Plus: **no-silence invariant** (§9.6) — over randomised phrase layouts, `effortDelivered > 0` for
every note, and no note's length or count changes.

### 13.4 The preview path

`Tests/DAWEngineTests/BreathPadPreviewTests.swift`

- Push a CC on the audition ring, run one `renderQuantum`, and assert an `EventCaptureInstrument`
  received a kind-2 event with the right controller and value. **This is the test that turns
  `InstrumentSourceNode.swift:731-743` from "happens to work" into a pinned contract** (§5.3 step 1).
- Assert `pitchToAuditionID` and `openAuditionCount` are **unchanged** across that push — the C11
  rule.
- Interleave a pad CC with an open audition note: the note must survive and its off must still pair.
- **Anti-vacuity (the `OutputDeviceTests` precedent):** assert the **real** `AudioEngine` returns
  something other than `.unsupported` from `previewController` for a track with an instrument node.
  Without this, a forgotten override leaves the `.unsupported` default and every other test passes.

### 13.5 Null tests — every new knob must have one

For each of `tremorDepth`, `driftDepth`, `vibratoAmDepth`, `biteDepth`, `air.enforced`: **at the
default value, the rendered bytes are identical to the pre-feature tree.** This is the discipline
`SamplerParams.expressionFilterDepth` already follows ("nil/0 = off so every pre-m27 project renders
bit-identically"). It is what makes each knob individually declinable after the fact.

### 13.6 The audibility test — the one that distinguishes "modulates" from "appears to modulate"

`Tests/DAWEngineTests/BreathPadAudibilityTests.swift`. **This is the most important test in the
plan** and it must assert on audio, not on data.

1. A `.sampler` track, one 4-second note, `expressionFilterDepth = 0.6`.
2. Render offline twice: pad off, pad on with a messa di voce at radius 1.
3. **Loudness:** compute a short-time RMS envelope of both. Assert the pad-on envelope has a
   **single interior maximum** near the pattern's peak position and a peak-to-trough ratio matching
   the requested depth within a stated tolerance. *Assert the pad-off envelope does NOT* — the
   negative control.
4. **Brightness:** compute a short-time spectral centroid. Assert it **rises and falls with** the
   RMS envelope (positive correlation above a threshold) in the pad-on render, and is flat in the
   pad-off render. This is the assertion that would have caught the inert-CC11 defect, because a
   stored-but-unrouted CC moves neither.
5. **Vibrato:** FFT the instantaneous-pitch track of the sustained portion; assert a peak at
   `vibratoRateHz` ± tolerance in pad-on and **no such peak** in pad-off.

⚠️ **Scope limit, stated rather than discovered later:** items 3–5 are automatable on the built-in
`.sampler`. On the `.soundBank` path they are **not** reliably automatable in this tree — hosting a
third-party AUv2 has wedged the main actor for minutes, and while Apple's own units are known to
load in 1–6 ms, an audio-rendering AU test is a different risk. **For the sound-bank path (the
user's sax), the plan is a scripted probe under `scripts/probes/`, rendered and measured with
`ffmpeg`/`ebur128`, run by hand.** ⚠️ Use `-hide_banner`, **not** `-v error` — `-v error` suppresses
the `ebur128`/`astats` summaries, which log at INFO. That has bitten this project twice.

### 13.7 Model-layer coherence

- `clip.getEffortField` (§12) sampled over a range must equal the values the committed lane
  actually carries at those beats, within rounding. **This is the cheapest cross-check in the plan**:
  it makes "the preview lies about what will be written" a test failure rather than a bug report.
- Round-trip: a project with `BreathPadSettings` encodes and decodes identically; a project *without*
  it decodes unchanged (schema-addition safety).

### 13.8 How to run, and how to read the result

`./scripts/test.sh` only — never bare `swift test`; the wrapper adds Testing.framework paths this
machine needs. When counting results, **positive-control the failure grep** (plant a `✘` on a line
and confirm the pattern finds it) before trusting a clean log, and re-measure **both** halves of any
`tests / assertions` pair rather than carrying one forward.

---

## 14. Full-Xcode dependencies — none, and the check that would change that

**Nothing in this design requires full Xcode.** No entitlements, no AUv3 hosting, no code signing,
no app bundling. Everything is SwiftPM-buildable (`swift build`) and testable
(`./scripts/test.sh`). The engine work in P6 is a change to an existing in-process source node and
an existing protocol.

Two things that would change that, neither of which is in scope:

1. If the pad ever needed to **host an AUv3 sidecar** for wind modelling (a SWAM-class instrument),
   that is AUv3 hosting and needs full Xcode plus entitlements.
2. If the pad ever needed **MIDI 2.0 / MPE per-note controllers** to escape the channel-wide bend
   limit (§4.3 item 4), that is a CoreMIDI capability question and should be re-scoped separately.

⚠️ Xcode 26.6 is installed on this machine, so any item filed as "blocked: needs full Xcode" should
be re-triaged before that blocker is re-quoted.

---

## 15. Failure modes

Ordered by how likely they are to be shipped without being noticed.

| # | Failure mode | Why it would go unnoticed | Defence |
|---|---|---|---|
| 1 | **The pad writes lanes that nothing consumes.** Track is `.sampler` with `expressionFilterDepth = 0`, or a hosted AU that ignores CC 11 | The verb succeeds, the lane is visible, the points are right. This is *literally today's defect* | Route every warning through `MIDIControllerRouting`; §13.6 asserts on **audio**, not data; §6.2's unrun experiment must be run before promising brightness on the sax |
| 2 | **Seed threaded but unread** — the pad returns the same curve for every seed | Every positive test passes | §13.1 assertion 2, the negative control |
| 3 | **Accumulating random walk** (§8.4) | It is deterministic given a seed, so it passes the naive determinism test. It only breaks on seek, loop, and mid-song bounce — i.e. in the user's real workflow, not in tests | §13.1 assertion 3, seek invariance |
| 4 | **Air budget attenuates silently** | The audio is arguably *better*; nobody looks for a report that is not there | §13.3 assertion 2; the unconditional "changed N of M notes" warning |
| 5 | **The preview becomes a streamer.** Someone "improves" the pad by letting it stream whenever the transport rolls | Sounds great. Bounces stop matching playback, and every offline-render gate in the tree quietly starts comparing the wrong thing | The `gesture: begin/move/end` wire shape (§12) makes the rule structural; a test that asserts no push happens without an open gesture |
| 6 | **The audition-ring contract gets "fixed" back.** A future reader sees CC on the audition ring, remembers the "producer bug" comment, adds a guard | The pad silently stops previewing; nothing else breaks | §5.3 step 1 amends the comment; §13.4 pins the behaviour with a test that names the reason |
| 7 | **`humanize` and the pad disagree about where a breath is** | Both are individually correct | §9.2: one factored classifier, two callers |
| 8 | **Committing during playback re-attacks notes** | It is the documented, user-ruled behaviour of `.continuation` chase — so it looks intentional | Commit on gesture end only, never per frame (§1.4). Consider deferring commit to transport stop as a user preference |
| 9 | **Lane point budget silently coarsens a long part** | Leg D already warns, but a pad that runs across a whole clip will hit it far more often than leg D did | Surface `perNotePointBudget` in the pad's own result and in the panel, not just in the wire response |
| 10 | **Zod/Swift parameter drift** — a new option added on one side only | Unknown keys are **silently stripped**; the call succeeds with a default | §12: add both in one change; test the key sets for equality |
| 11 | **Equal-power blend used for curves** | The output looks plausible and is ~1.41× too big in the middle of a blend | §13.2 identity-under-self-blend |
| 12 | **Tremor and vibrato phase-lock** into one deeper vibrato | Sounds fine, just less human | §10.1: detune or drive tremor from a different fBm octave |

---

## 16. Cost, in terms the user can weigh

Rough, and stated as ranges rather than false precision. "Leg D" is the unit: m27 leg D was one
pure DAWCore file (656 lines), one store extension (356), one wire handler, one MCP tool, and its
tests — a single focused session.

| Phase | Rough size | What you get if you stop here |
|---|---|---|
| **P1** pattern library + verb | **≈ 1 × leg D** | Named, musically-meaningful effort shapes applicable per note or per phrase, over the wire and from MCP. Already a real feature |
| **P2** circular morph | **≈ 0.4 × leg D** | The user's own idea, working: patterns on a ring, blend anywhere between them |
| **P3** dot paths | **≈ 0.7 × leg D** | "Flow from one pattern to the other", reproducibly |
| **P4** air budget | **≈ 1 × leg D** (most of it is the report and the warnings, not the model) | The constraint the user asked for, and it announces itself |
| **P5** humanisation | **≈ 0.2 × leg D** | Micro-tremor and drift |
| **P6** live preview | **≈ 0.6 × leg D**, but it is the only leg touching DAWEngine and therefore the only one needing RT-safety review | The control feels like an instrument |
| **P7** panel | **≈ 1.5 × leg D** | The circle, the dot, the trail, breath marks, the air gauge |
| **Total (P1–P7)** | **≈ 5–6 × leg D** | One focused milestone with 3–4 delegated legs |
| **(b) engine modulation source** | **≈ 15–20 × leg D**, plus permanent RT surface and a new architecture to maintain | Capabilities §4.3 items 1–2, on `.sampler` only |

**The headline:** P1 + P2 + P4 is **≈ 2.4 × leg D** and delivers standard patterns, the circular
blend, and an enforced-and-legible air budget — with **zero engine work and zero new RT surface**.
That is the "90 % for 20 %" answer. The remaining 10 % is P3's automatic motion, P6's feel, and
P7's visual, and those are the parts that turn a good feature into the instrument the user
described.

---

## 17. Open questions that need the user's word

Offered as options. None of these should be decided by an implementing agent.

1. **Take the whole thing, or the P1+P2+P4 minimum?** (§0.1)
2. **`air.enforced` default — `false` (recommended, §9.5) or `true`?** `true` matches "should the
   air-budget constraint be enforced — yes" most literally; `false` matches this tree's rule that a
   feature which overrides composer intent is opted into. **My recommendation is `false` with a
   prominent, easy-to-find switch in the panel** — but the user's stated intent is a legitimate
   reason to overrule me.
3. **`vibratoAmDepth` default — 0 (byte-identical to today) or 0.10 (better, sourced, but changes
   existing renders)?** (§6.4) This is a rendered-bytes decision of the same class as m23-bv, which
   they ruled on before.
4. **Should the pad commit on gesture end, or defer to transport stop?** Committing while rolling
   causes the documented `.continuation` re-attack (§1.4, failure mode 8). Deferring avoids it but
   means the thing you heard is not yet the record for a while.
5. **Ring size — 8 (recommended) or 6?** Six is easier to read at small panel sizes; eight covers the
   library without leaving a pattern off the circle.
6. **Run the 5-minute sax experiment first?** (§6.2) It settles whether the stock GM sax honours CC 1
   vibrato, what AUSampler's real bend range is, and whether CC 11 moves brightness there at all.
   **My recommendation: yes, before P1.** If CC 11 does not move brightness on the sound-bank path,
   several claims in this document get weaker and the doc should say so rather than promise it.

---

## 18. Text for `docs/ARCHITECTURE.md` → "Key future decisions"

**Not applied.** This decision is not settled — the user has not ruled. The block below is written
so it can be pasted under `docs/ARCHITECTURE.md`'s `## Key future decisions` heading (line 223) at
the moment they do, with the bracketed parts filled in.

> - **Expressive modulation route (breath pad, DESIGNED 2026-08-19, NOT YET RULED) — CC LANES, NOT
> AN ENGINE MODULATION SOURCE.** The design
> (`docs/research/design-breath-pad.md`) evaluated a general per-block `ModulationSource` in
> DAWEngine and **rejected it**. Three reasons, in order of decisiveness. (1) **It does not reach
> the instrument the feature exists for.** A `.soundBank`/`.audioUnit` track can only be driven by
> MIDI bytes (`HostedAUInstrument.swift:203` emits `0xB0`), so a per-block source would have to be
> re-quantised into CC events to reach an AUSampler — arriving back at CC lanes with extra steps.
> It would be a full win only on the built-in `.sampler`. (2) **Its unique capability is forbidden
> by the reproducibility requirement.** The only thing a render-time source can do that a baked lane
> cannot is vary with wall-clock time; the user's own constraint requires effort to be a pure
> function of musical position + seed + path, and once that holds, everything the source would
> compute at render time is knowable at prepare time. (3) **Determinism becomes an obligation
> instead of a structural property** — with a lane, bounce-equals-playback is true because it is the
> same event array; with a source it must be re-proved against all four `RescheduleCause` policies,
> ⚠️ **REASON (1) IS CONDITIONAL AND THE CONDITION IS UNMEASURED.** It assumes the `.soundBank` path
> consumes CC 11 usefully — that assumption is what makes "a per-block source would only be
> re-quantised back into CC" decisive. **It has not been measured on the stock GM sax**
> (`AUHostRegistry` never configures the AUSampler's bend range either, so leg D's
> `bendRangeSemitones: 2` default is likewise unverified there). The five-minute render described in
> `design-breath-pad.md` §6.2 settles it. If CC 11 turns out to move nothing on that path, reason (1)
> does not merely weaken — it **changes shape**, because then neither route reaches that
> instrument's timbre and the comparison has to be redone. Reasons (2) and (3) stand independently of
> the outcome. ⛔ **Do not quote this entry as a settled rejection until §6.2's experiment has run.**
> loop unrolling and seek. What is adopted instead: a **pure DAWCore effort model** (patterns on a
> circle, angle/radius weights, seeded fBm dot paths, an air budget) that emits CC/pitch-bend lanes
> through m27 leg D's `applyBreathContour`, plus a **drag-only** live preview over the m23-d
> audition ring. ⚠️ **THE PAD LAW: the pad never streams while the transport is merely rolling.**
> Streaming happens if and only if a user gesture is in progress; with no gesture, what sounds is
> the committed lane and nothing else — so playback, replay and offline bounce agree
> sample-for-sample by construction. The preview is explicitly *not* the record, the same contract
> `pushAudition` already carries for piano-roll note audition. ⚠️ The **random walk is
> position-pure fBm over a pinned hash, never an accumulator**: an accumulating walk is
> deterministic-given-a-seed and still wrong, because a bounce from bar 33 would take a different
> path than playing through bar 33 — and no naive determinism test catches it.
> **(b) remains a legitimate future milestone**, but it must be justified by a feature that needs
> render-time evaluation — a real synth with LFOs, or per-voice random humanisation on the built-in
> sampler — not by the breath pad, which does not need it.

---

## 19. Sources

**Verified for this document** (fetched 2026-08-19):

- Spectrasonics Omnisphere — the Orb: [manual, Orb index](https://support.spectrasonics.net/manual/Omnisphere3/30/en/topic/orb-index) · [Orb as Mod Source](https://support.spectrasonics.net/manual/Omnisphere2/25/en/topic/orb-page07) · [Orb MIDI Learn](https://support.spectrasonics.net/manual/Omnisphere/main/orb/page06.html)
- Korg Wavestation: [Wikipedia](https://en.wikipedia.org/wiki/Korg_Wavestation) · [Making the Most of Your Korg Wavestation (SOS)](http://www.chriscarter.co.uk/content/sos/korg_ws_ad.html)
- Sequential Prophet VS: [Wikipedia](https://en.wikipedia.org/wiki/Prophet_VS) · [Vector synthesis](https://en.wikipedia.org/wiki/Vector_synthesis) · [SOS Retrozone](https://www.soundonsound.com/reviews/sequential-prophet-vs-retrozone)
- TEControl BBC2: [product page](https://www.tecontrol.se/products/usb-midi-breath-bite-controller-2) · [user manual PDF](https://www.tecontrol.se/files/MIDI%20BBC2%20Users%20manual.pdf) · [KVR listing](https://www.kvraudio.com/product/usb-midi-breath-and-bite-controller-2-by-tecontrol)
- Audio Modeling SWAM: [SWAM Saxophones](https://audiomodeling.com/products/swam-saxophones) · [Solo Woodwinds v3.0.0 manual](https://static.audiomodeling.com/manuals/woodwinds/SWAM%20Solo%20Woodwinds%20-%20User%20Manual%20-%20v3.0.0.pdf) · [KB: velocity-only control](https://kb.audiomodeling.com/support/solutions/articles/206000050973-is-it-possible-to-control-swam-instruments-using-only-note-on-velocity-)
- Saxophone vibrato (~5 Hz, ~10 % blowing-pressure variation; AM of upper partials): [Vibrato of saxophones](https://www.researchgate.net/publication/7502176_Vibrato_of_saxophones)

**Abstract-level only — summaries read, papers NOT opened.** Do not quote these as measurements
without reading them first:

- [Objective characterization of saxophone mouthpiece playability](https://www.sciencedirect.com/science/article/abs/pii/S0003682X2300107X) (the 2–3 kPa figure)
- [Blowing Pressures in Bassoon, Clarinet, Oboe and Saxophone](https://www.researchgate.net/publication/233620195_Blowing_Pressures_in_Bassoon_Clarinet_Oboe_and_Saxophone)
- [Modeling of Wind Instruments](https://link.springer.com/chapter/10.1007/978-3-662-55004-5_7) (the >120 cm H₂O figure)
- [Flicker noise](https://en.wikipedia.org/wiki/Flicker_noise) — general background only; **no** wind-specific 1/f measurement was found

**Unverified recollection — none.** Every prior-art claim in §3 was checked. Every number without a
source is marked **(estimate)** at its point of use, following `BreathContour.swift`'s own
convention.

**In-tree sources read for this design** (all line references from branch `m23-wip-2026-08-10`,
2026-08-19): `Sources/DAWCore/BreathContour.swift` · `Sources/DAWCore/ProjectStore+BreathContour.swift` ·
`Sources/DAWCore/MIDIControllerRouting.swift` · `Sources/DAWCore/EngineProtocol.swift` ·
`Sources/DAWCore/ProjectStore+Humanize.swift` · `Sources/DAWEngine/InstrumentSourceNode.swift` ·
`Sources/DAWEngine/Instruments/SamplerInstrument.swift` · `Sources/DAWEngine/MIDISchedule.swift` ·
`Sources/DAWEngine/PlaybackGraph.swift` · `Sources/DAWEngine/AudioEngine.swift` ·
`Sources/DAWEngine/RescheduleCause.swift` · `Sources/DAWEngine/MIDIInput/LiveEventRing.swift` ·
`Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift` · `Sources/DAWControl/Commands.swift` ·
`mcp-server/src/server.ts` · `docs/ARCHITECTURE.md`.
