# Measuring the stock GM sound bank: CC 1, pitch-bend range, CC 11

**Status: COMPLETE (2026-08-19). All three questions answered from rendered audio;
every control fired.** Nothing below reads `PENDING`. §5.5 states plainly what was
*not* measured — read it before quoting any figure outside its scope.

**The three answers in one line each:**

- **Q1 — CC 1 is vibrato: YES.** Depth linear in CC1, `≈ 2.42 + 0.2996 × CC1` cents, at a fixed 5.400 Hz.
- **Q2 — bend range: ±2.0155 semitones.** Leg D's `bendRangeSemitones: 2` is correct to 0.78 %; no correction needed.
- **Q3 — CC 11 brightness: NO. Loudness only**, and *exactly* a gain — any other difference bounded at −104 dB.

⛔ **And one finding nobody asked for, which outranks all three in impact:
pitch-bend lanes are SAMPLE-AND-HELD at the render block rate on the hosted-AU
path in a bounce — an 11.719 Hz sampler whose Nyquist is 5.86 Hz (§2.3, §2.3a).
Leg D's own 5.5 Hz vibrato comes out as TWO vibratos beating against each other
(35.4 cents at 5.50 Hz plus a 30.0-cent alias at 6.22 Hz); an 8 Hz vibrato comes
out mostly as a 3.72 Hz wobble; an 11.72 Hz vibrato comes out as a static
−17.9 cent detune. The built-in `.sampler` has none of this.**

This answers the three unrun questions flagged in
`docs/research/design-breath-pad.md` §6.2 item 2 (lines 623-631). It is a
**measurement**, not a feature. No product code, wire verbs or MCP tools were
added.

---

## 0. Method, common to all three questions

### 0.1 The path under test

The user's saxophone is a `.soundBank` track: Apple's `gs_instruments.dls`
(`/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls`,
named at `Sources/DAWCore/SoundBanks.swift:140`) loaded into Apple's AUSampler
and hosted by `Sources/DAWEngine/AudioUnits/HostedAUInstrument.swift`.

Controller data reaches it as raw MIDI. Verified in-tree at
`HostedAUInstrument.swift:202-211`:

- `controlChange` → `0xB0`, `data1` = controller#, `data2` = value
- `pitchBend` → `0xE0`, `data1` = LSB, `data2` = MSB

Controller lanes survive into an offline render: `OfflineRenderer.swift:387`
calls `graph.scheduleAll(… cause: .offlineRender)`, and the schedule builder's
controller-lane pass is `MIDISchedule.swift:205-263`. So `render.bounce` is a
legitimate instrument for this question — the same event stream the live
render path uses.

### 0.2 Drive and capture

A probe (`scripts/gates/_measure-gm-sax-cc.mjs`, `_`-prefixed so gate discovery
skips it — `_verdict.mjs:174`) drives a **staging** app on port **17695** over
the control WebSocket. Port 17600 (the user's live app) is never contacted;
`assertStagingPort` enforces it.

Each trial: one instrument track, one MIDI clip holding one note, controller
lanes authored with `clip.setControllerLane`, then `render.bounce` to a temp
`.wav`. **`lufsTarget` is omitted on every bounce** so the render is
un-normalised and level differences are real. The 32-bit-float default output
format is kept (no `bitDepth`), so nothing clips and the noise floor stays
where the engine put it.

### 0.3 Analysis

WAVs are converted with `ffmpeg -hide_banner … -f f32le -ac 1` and read as raw
floats — no hand-rolled WAV parsing (Apple's writers emit
`WAVE_FORMAT_EXTENSIBLE`, which a naive parser mis-reads as data rather than
failing).

- **f0 over time**: heterodyne. Multiply by `exp(-i·2π·f_ref·t)`, low-pass,
  unwrap phase, differentiate → instantaneous frequency. Gives cents-level
  precision on a steady tone.
- **Amplitude over time**: RMS envelope, ~1 ms hop.
- **Modulation**: DFT of the (mean-removed) cents trace and of the
  (mean-removed) envelope, peak sought in 2-12 Hz.
- **Timbre**: Hann-windowed magnitude spectrum over a fixed window; spectral
  centroid and a high/low band energy ratio.

⚠️ **On "normalise before comparing timbre".** Spectral centroid
`Σf·|X| / Σ|X|` and any band-energy *ratio* are already **invariant** under a
gain multiply — the scale factor cancels top and bottom. RMS normalisation is
performed anyway (it is free and makes the comparison auditable), but the
invariance is worth stating because it makes a centroid null *stronger*, not
weaker: a pure gain change **cannot** move these metrics, so if they do not
move, gain is all that happened.

The confound that is real is the **noise floor**: a quieter render carries a
relatively larger fixed floor, which biases centroid *upward* — i.e. it would
fake "CC11 opens a filter as it closes". SNR is therefore reported alongside.

### 0.4 Controls — the whole point

A null is uninterpretable without a control that fires through the identical
chain. Three are run:

| Control | Proves | Expected |
|---|---|---|
| **C1** — built-in `.sampler`, `expressionFilterDepth: 1.0`, CC11 127 vs 40 | the timbre chain can see a filter | centroid moves |
| **C2** — authored pitch-bend vibrato on the DLS sax itself | the f0 tracker finds known modulation, and bend bytes reach AUSampler | ~5 Hz at the commanded depth |
| **C3** — built-in `.sampler`, bend centre vs max | the bend maths is right (`SamplerInstrument.swift:308` hard-codes `bendRangeSemitones = 2.0`) | 200 cents |

Every rendered file is asserted non-silent before analysis. A centroid computed
on silence is a number, not an error.

### 0.5 Two trials added mid-measurement, and why

Neither was in the original plan; both exist because a measured number did not
fit and was chased rather than rounded off.

| Trial | Added because | Found |
|---|---|---|
| **Q2-SWEEP** | Q2's two-point bend read 201.65 cents where C3's known-200 control read 199.97. Two points cannot separate a range error from an offset or a curve. | Linear, no offset, ±2.0155 st (§2.1) |
| **BENDLPF** | C2 recovered only 74 % of its commanded vibrato depth — far too much for a 0.78 % range error. | The 85.33 ms bend quantisation (§2.3) — the biggest result in this document |
| **ALIAS-SCAN** | BENDLPF measured only the commanded rate, which cannot tell block-*averaging* from sample-and-*hold*. | It is a sample-and-hold: alias images at \|f_s − f\| (§2.3a), several of them louder than the fundamental |

`scripts/gates/_measure-alias-scan.mjs` needs **no app** — it re-analyses the
BENDLPF renders. Run the `bendlpf`/`bendlpfb` trials first, then it.

### 0.6 The strongest instrument here is not in §0.3: the scalar fit

Comparing summary statistics can only ever say "these two numbers did not
move." Because `render.bounce` is **deterministic**, a much stronger question is
available: least-squares-fit a single scalar `g` with `y ≈ g·x` between two
renders and report the unexplained residual `‖y − g·x‖ / ‖y‖`.

- A **pure level change** fits perfectly — residual falls to the float
  renderer's own floor (≈ −104 dB, observed).
- **Anything else at all** — a filter, a phase shift, a timing difference, a
  different sample — cannot be absorbed by one scalar and leaves a large residual
  (C1's real filter: −9.75 dB).

The two cases are separated by **95 dB**, which is what turns Q3 from "we
detected no brightness change" into "there is no change beyond a gain, bounded
at −104 dB." C1 doubles as the negative control proving the fit does not simply
read "pure gain" for everything.

---

## 1. Q1 — Does the GM sax honour CC 1 (mod wheel) as vibrato? **YES — PITCH VIBRATO, LINEAR IN CC1** (2026-08-19)

**Answer: yes. CC 1 sets the DEPTH of a 5.400 Hz pitch vibrato, linearly, from
±2.4 cents at CC1 = 0 to ±40.5 cents at CC1 = 127. It is pitch-only: it moves
amplitude by 0.16 dB, which does not change with CC1 and is below any musical
threshold.**

Same fixture as Q3 (Tenor Sax, program 66, held D4, 6 s), three arms, analysed
1.0–4.5 s after onset.

| CC 1 | vibrato rate | vibrato depth | prominence | AM depth | steady RMS |
|---|---|---|---|---|---|
| 0 | 5.400 Hz | **±2.418 cents** | 1791 | ±0.161 dB | −24.269 dBFS |
| 64 | 5.400 Hz | **±21.592 cents** | 2275 | ±0.160 dB | −24.269 dBFS |
| 127 | 5.400 Hz | **±40.468 cents** | 2198 | ±0.159 dB | −24.269 dBFS |

All three clear the conjunctive rule on pitch (depth ≥ 1 cent **and**
prominence > 20). None clears it on amplitude (0.5 dB floor).

### 1.1 The mapping is linear, and that is directly usable

    depth_cents ≈ 2.42 + 0.2996 × CC1        (±0.005 cents at the midpoint)

The CC1 = 64 arm was added purely to test this, and it predicts 21.593 against
21.592 measured. A design that needs "±12 cents of vibrato" can solve for
CC1 ≈ **32**.

**Rate is fixed at 5.400 Hz and does not respond to CC1 at all** (measured on a
0.001 Hz grid). It is not adjustable over MIDI on this path. That is close to
the ~5 Hz the saxophone literature reports, which is a lucky accident, not a
control.

### 1.2 ⚠️ THE NEGATIVE CONTROL CHANGED THE ANSWER'S SHAPE — READ THIS

The trial was built expecting that any modulation at CC1 = 0 would be a **DLS
loop artefact**, and its verdict was coded as
`detected(CC1=127) && !detected(CC1=0)`.

That is the wrong discriminator, and it fired: there is a **genuine always-on
vibrato LFO** at CC1 = 0 (±2.42 cents), so `!detected(CC1=0)` is false and the
boolean reported **"CC1 does not drive vibrato" about a 16.7× depth change**.

A loop artefact and a driven LFO are separated by *response*, not by presence:

- a loop artefact would show the **same depth** in every arm
- what is here holds its **rate** at 5.400 Hz while its **depth** tracks CC1 linearly

The probe now tests exactly that (`cc1DeepensVibrato`). Recorded because it is
the same failure class the rest of this document exists to remove — a
correctly-computed number under a wrongly-shaped question.

### 1.3 The patch imposes its own ~0.53 s vibrato delay, and it is not ours to control

Scanning the cents trace per LFO half-cycle from note-on (CC1 = 127):

| s from note-on | 0.03 → 0.43 | 0.45 | 0.47 | 0.49 → 4.5 |
|---|---|---|---|---|
| peak \|cents\| | flat **1.4–1.5** (noise floor) | 2.8 | 24.4 | **45–50** |

**The LFO is gated off for the first ~0.53 s, then reaches full depth within
~40 ms.** It is a delay-then-switch, not a ramp, and the timing is identical at
CC1 = 0 and CC1 = 127 — a property of the patch, not of the controller.

⚠️ **This STACKS with leg D's own delayed vibrato** ("straight for the first
~0.5 s, then blooming" — `CopilotCatalog.swift:580`). A note shorter than
~0.6 s gets no CC1 vibrato at all, and a pad that delays its own vibrato by
0.5 s and then drives CC1 would not be heard until ~1 s in.

### 1.4 The amplitude arm: a null, and a clean one

±0.16 dB at 5.400 Hz in every arm, *decreasing very slightly* as CC1 rises
(0.161 → 0.160 → 0.159 dB). Since it does not grow with the pitch vibrato that
grows 16.7×, it is not a by-product of it, and it is not CC1-driven. Whatever
it is, it is 0.16 dB and inaudible.

**So CC 1 is a pitch-vibrato control on this path and nothing else** — no
tremolo, no timbre, and no level change (RMS identical to 0.001 dB across all
three arms). `clip.setControllerLane` returned **no warning** for the CC1 lane.

## 2. Q2 — What is AUSampler's actual pitch-bend range? **±2.0155 SEMITONES** (2026-08-19)

**Answer: ±2.0155 semitones (201.55 cents for full deflection), linear, with no
offset. Leg D's `bendRangeSemitones: 2` default is CORRECT on the sax path to
within 0.78 %.**

### 2.1 The number

Two independent trials, both on Tenor Sax / D4:

| Trial | Method | Result |
|---|---|---|
| Q2 | bend stepped mid-note, 8192 → 16383, one render | 201.65 cents = **±2.0167 st** |
| Q2-SWEEP | six levels in one render, each analysed over exactly 4 LFO cycles | **±2.0155 st** |

Q2-SWEEP is the figure to quote. Six levels, least-squares slope through the
origin:

| bend units above centre | 0 | 1638 | 3277 | 4915 | 6554 | 8191 |
|---|---|---|---|---|---|---|
| measured | 0 | 40.310 | 80.713 | 120.879 | 161.334 | **201.457** |

Slope **0.02460374 cents/unit**, **max residual 0.087 cents**. The response is
linear in cents with no detectable offset or curvature, so the two-point
measurement was not hiding a non-linearity.

Each window is exactly 4 cycles of the 5.400 Hz LFO Q1 found (0.7407 s), which
nulls the bias that an always-on ±2.42 cent vibrato would otherwise put on a
mean-frequency estimate. Without Q1 having been run first, this trial would
have carried an unmodelled ±0.1-cent-class error.

### 2.2 The correction factor, stated explicitly

    measured / assumed = 2.0155 / 2 = 1.0078   →   +0.78 %

**Every vibrato and micro-sharpening figure in the breath-pad design is
therefore correct to within 0.8 % on the sax path.** A commanded ±12 cent
vibrato lands at ±12.09 cents; a commanded 5 cent micro-sharpening lands at
5.04 cents. Nothing in the design needs rescaling, and the brief's contingency
("any other value means every figure is proportionally wrong") does not fire.

**C3 confirms the measurement rather than the plugin**: the built-in `.sampler`,
whose `bendRangeSemitones` is hard-coded to exactly 2.0
(`SamplerInstrument.swift:308`), measured **199.97 cents** through the identical
chain. So the chain reads a known 200 as 200, and the sax's 201.55 is a real
0.78 % property of AUSampler, not an artefact.

### 2.3 ⛔ THE FINDING THAT MATTERS MORE THAN THE RANGE: bend is SAMPLED, not smoothed, on the hosted path

C2 recovered only **74 %** of its commanded vibrato depth. That is far too big
to be a 0.78 % range error, so it was chased.

Authored ±50-cent bend vibrato at seven rates, GM sax:

| rate (Hz) | 2.0 | 3.5 | 5.5 | 8.0 | 11.0 | **11.72** | 14.0 |
|---|---|---|---|---|---|---|---|
| depth recovered | 95.1 % | 86.4 % | 70.8 % | 38.5 % | 6.4 % | **0.03 %** | 14.7 % |

**At 11.72 Hz the vibrato disappears entirely (0.013 cents of 50), and above it
the depth COMES BACK.** A null followed by a recovering sidelobe is not
something a smoothing filter can produce — it is the signature of a **block
operation of period T**, `|sinc(π f T)|`, whose first null sits at `f = 1/T`.

`1 / 11.719 Hz` = **85.33 ms** = **4096 frames at 48 kHz**.

⚠️ This response is shared by block *averaging* and sample-and-*hold*, which
have very different consequences. **§2.3a resolves which — do not read this
section on its own.**

The one-pole hypothesis is rejected outright: its implied time constant ranges
from 25.9 ms to 50.9 s across the band. The sinc model with T = 4096 frames
predicts **six of the seven points within 0.7 percentage points**:

| rate | 2.0 | 3.5 | 5.5 | 8.0 | 11.0 | 11.72 | 14.0 |
|---|---|---|---|---|---|---|---|
| error vs sinc(4096) (pp) | −0.19 | +0.41 | **+3.33** | −0.70 | −0.13 | +0.02 | −0.56 |

⚠️ The 5.5 Hz point is the one outlier and its cause is known: 5.5 Hz cannot be
resolved from the patch's own 5.400 Hz LFO in a 3.5 s trace (Hann main lobe
≈ 1.14 Hz), so the always-on vibrato adds energy to the measurement. It is
reported rather than dropped, and it is why the other six were placed away from
5.4 Hz.

### 2.3a ⛔⛔ IT IS A SAMPLE-AND-HOLD, AND THAT IS MUCH WORSE THAN AN ATTENUATION

The table above measures only *how much of the commanded rate survives*. That
is the wrong question to stop at, because two mechanisms share it and differ
completely in consequence:

- **block averaging** → sinc rolloff and nothing else. A shallower vibrato.
- **sample-and-hold at the block rate** → sinc rolloff **plus alias images at
  `|k·f_s ± f|`**. A *different* vibrato.

With `f_s = 11.719 Hz`, those images land inside the vibrato band. Re-analysing
the **same renders** (no new audio), taking local maxima across 0.5–20 Hz
instead of only the global peak:

| commanded | survives at commanded rate | **image appears at** | **image depth** |
|---|---|---|---|
| 2.0 Hz | 47.5 cents | 9.72 Hz | 9.7 cents |
| 3.5 Hz | 43.2 cents | 8.22 Hz | 18.2 cents |
| **5.5 Hz** | 35.4 cents | **6.22 Hz** | **30.0 cents** |
| 8.0 Hz | 19.2 cents | **3.72 Hz** | **41.7 cents** |
| **11.0 Hz** | **3.2 cents** | **0.72 Hz** | **49.8 cents** |
| 14.0 Hz | 7.4 cents | **2.28 Hz** | **46.5 cents** |

Every image sits at exactly `|11.719 − f|`. **At 8, 11 and 14 Hz the alias is the
LOUDER component** — the vibrato you hear is not the vibrato that was authored;
it is a slow wobble at a rate nobody asked for. The 11 Hz case is the starkest:
a commanded ±50 cent, 11 Hz vibrato is delivered as **±49.8 cents at 0.72 Hz** —
essentially full depth, at one-fifteenth the rate. That is not a degraded
vibrato, it is a slow pitch drift.

And at `f = f_s` the output is not silence, as §2.3's table suggested, but **DC**:
the 11.72 Hz render is a **static −17.89 cent detune** (mean f0 290.687 Hz
against 293.706 Hz in the 2 Hz arm). Sampling one phase of a sinusoid repeatedly
gives a constant, which is exactly what a hold does and what an averager cannot.

⚠️ **The Nyquist rate of this sampler is 5.86 Hz.** Above it, authored vibrato
**folds down**. Leg D's default is **5.5 Hz — just below the fold**, which is why
its symptom is not a wrong rate but the ugliest case of all: two components of
comparable size (35.4 cents at 5.50 Hz, 30.0 cents at 6.22 Hz) **beating against
each other with a 1.39 s period.** The result is an uneven, lurching vibrato, not
a shallow one.

**Negative control — the built-in `.sampler`, same rates, same analysis:**

| commanded | 2.0 | 3.5 | 5.5 | 8.0 | 11.0 | 11.72 | 14.0 |
|---|---|---|---|---|---|---|---|
| depth at commanded rate | 49.9 c | 49.9 c | 49.6 c | 49.2 c | 48.5 c | **48.3 c** | 47.6 c |
| image at \|f_s − f\| | absent | absent | absent | absent | absent | — | absent |

A single clean peak every time, ~49 cents of a commanded 50, **no images at any
rate**, and **48.3 cents delivered at 11.72 Hz where the hosted path delivers
zero**. Reproduced by `scripts/gates/_measure-alias-scan.mjs`: 6 images on the
hosted path, **0** on the built-in, across 14 renders.

⚠️ **The detector needed a second pass and it matters.** A Hann window puts
sidelobes ±0.68 Hz either side of every peak at ~2.6 % of it, and a bare
"is there a peak near the predicted frequency" test duly *found* an image in the
built-in control at 5.5 Hz — the 6.18 Hz sidelobe of its own 5.50 Hz peak. That
one false positive would have collapsed the negative control and with it this
whole section. An image now has to be both > 3 cents absolute and > 10 % of the
fundamental. **The control that clears your hypothesis is exactly the one to
distrust first.**

⭐ **This was nearly missed.** The first write-up measured only the commanded
rate, found a clean sinc fit, and concluded "boxcar." The fit was correct and
the conclusion was half the story — the same shape of error §1.2 records for
Q1's verdict. **A model that predicts your measurements can still be the wrong
model if you only measured what it predicts.** The tell was in the data already:
C2's prominence of 156.7 against Q1's ~2000 is not explainable by a ±2.4 cent
LFO beside a ±37 cent one, and a second large component is exactly what would
depress peak-over-median that far.

### 2.4 Whose 4096 is it? Ours — and that has a consequence

The identical test on the **built-in `.sampler`**, same renderer, same schedule,
same lane, same analysis:

| rate (Hz) | 2.0 | 3.5 | 5.5 | 8.0 | 11.0 | 11.72 | 14.0 |
|---|---|---|---|---|---|---|---|
| depth recovered | 99.9 % | 99.7 % | 99.3 % | 98.4 % | 97.0 % | **96.7 %** | 95.3 % |

**No null, no quantisation** — a clean one-pole with a consistent τ of
3.53–3.63 ms. So the hold is not in the scheduler, the lane, or the renderer's
event delivery, all of which are shared.

`HostedAUInstrument.render` does deliver each event at its exact in-quantum
offset (`scheduleMIDI(AUEventSampleTimeImmediate + offset, …)`,
`HostedAUInstrument.swift:190-219`), so the host code is correct.
**AUSampler applies pitch bend once per render call and ignores the offset.**

⭐ **And the quantisation is in MIDI EVENT APPLICATION ONLY — not in pitch
generation.** The proof is already in Q1: the patch's *own* 5.400 Hz vibrato
LFO, an AU-internal modulator, comes back at **40.468 cents** with its
would-be image at 6.32 Hz sitting at **0.254 cents** (159× down). Were
AUSampler's pitch output block-quantised, that LFO would itself be attenuated to
68.6 % and would alias. It is not. **AUSampler computes pitch per sample and
merely reads its MIDI inputs per block.**

That distinction is what makes §5.2's recommendation work: **a controller that
sets a DEPTH is immune, while a controller that carries a WAVEFORM is not.**

But the *period* of that quantisation is **our** block size:
`OfflineRenderer.maximumFrameCount` defaults to **4096**
(`OfflineRenderer.swift:105`), and both bounce call sites construct
`OfflineRenderer()` with no argument (`AudioEngine.swift:2099, 2144`).
4096 / 48000 = 85.33 ms — exactly the measured hold period.

⚠️⚠️ **PREDICTION, NOT MEASURED — AND FALSIFIABLE.** Live playback pulls at the
hardware buffer size, not 4096. At a typical 512 frames (10.67 ms) the first
sampling rate rises to 93.75 Hz (Nyquist 46.9 Hz), so a 5.5 Hz vibrato would
arrive at ~99.8 % of depth with its image pushed to 88.25 Hz — far outside the
vibrato band and inaudible as one. If that is right, **a bounce of a sound-bank
track carries a vibrato the user never heard while approving it** — the same
project, rendered two ways, differing not just in depth but in RATE. I could not test it here: the
render sample rate and block size are not reachable from the wire, and there is
no capture path for live playback in this harness. **The falsifying test is to
construct `OfflineRenderer(maximumFrameCount: 512)` and re-run the 11.72 Hz
point — if the null moves to 93.75 Hz, the mechanism is confirmed and the
default is a bounce-fidelity bug.** Route: `daw-architect` / `audio-dsp-engineer`.

## 3. Q3 — Does CC 11 move brightness, or only loudness? **LOUDNESS ONLY** (2026-08-19)

**Answer: CC 11 on the stock GM sax is EXACTLY a gain change. Not "no brightness
change we could detect" — no change of any kind beyond a scalar multiply,
bounded at −104 dB.**

Trial: `Tenor Sax` (GM program **66**, bank MSB 121 / LSB 0, resolved by NAME
from `instrument.listSoundBankPrograms` — never from GM numbering), one held
D4 (MIDI 62, 293.665 Hz) at velocity 100, 6 s long, analysed 1.0–4.5 s after
onset. Four arms, one render each.

| Arm | RMS (dBFS) | centroid (Hz) | bandRatio | f0 (Hz) |
|---|---|---|---|---|
| CC11 = 127 | **−24.269** | 2716.55 | 0.244634 | 293.657 |
| CC11 = 40 | **−44.339** | 2716.55 | 0.244634 | 293.657 |
| no CC11 lane at all | −24.269 | 2716.55 | 0.244634 | 293.657 |
| CC7 = 40 (no CC11 lane) | −40.187 | 2716.55 | 0.244634 | 293.657 |

`bandRatio` factor **1.000000**. `centroid` factor **1.000000**. Twelve-harmonic
profile identical to 0.01 dB in all four arms.

### 3.1 The measurement that makes this an assertion rather than a null

Two summary statistics failing to move is weak evidence — a change could slip
past both. So the difference was tested directly: least-squares-fit a **single
scalar** `g` with `y ≈ g·x`, then report the unexplained residual.

| Comparison | fitted gain | residual |
|---|---|---|
| CC11 127 → 40 | **−20.0698 dB** | **−104.35 dB** |
| CC7 default → 40 | **−15.9176 dB** | **−103.09 dB** |
| CC11 = 127 vs no lane | 0.0000 dB (g = 1.000000) | **−∞ (bit-identical)** |

A residual of −104 dB is the deterministic float renderer's own numerical
floor. **One scalar explains the entire difference between the two renders** —
every spectral, temporal and phase difference at once, not just the two metrics
in the table. There is no filter on this path to find.

And the fitted gains are not merely small, they are *predicted*:

- CC11: measured **−20.0698 dB**, MIDI square law `(40/127)²` = **−20.0697 dB**
- CC7: measured **−15.9176 dB**, `(40/100)²` = **−15.9176 dB**

Both controllers are exact amplitude scalers obeying the standard
`(value/reference)²` law. CC7's reference is **100**, not 127 — the GM
power-on default — which is why its arm moves less for the same controller
value.

### 3.2 Two things this trial establishes that Q1 then depends on

1. ⭐ **CC BYTES DEMONSTRABLY REACH THE DLS SAX OVER THIS EXACT PATH.** A 20 dB
   level move proves delivery. Without it, a Q1 null would be two hypotheses
   wearing one number — "the patch has no mod-wheel routing" versus "the lane
   was never delivered" — and the measurement could not tell them apart.
2. ⭐ **CC 11 DEFAULTS TO 127**, measured, not assumed: the no-lane render is
   **bit-identical** to the CC11 = 127 render (residual −∞). This is the first
   direct confirmation of a claim the codebase already warns about in prose.

### 3.3 Noise floor: the confound §0.3 anticipated does not exist here

Every render's pre-note window (0.05–0.90 s) is **digital silence** — peak
absolute sample exactly `0`, not merely low. SNR is therefore unbounded in all
four arms, and the "quiet render biases centroid upward" mechanism §0.3 warned
about has nothing to act on. The offline renderer emits no dither and no
self-noise, so the level-normalisation argument in §0.3 is moot in both
directions.

`clip.setControllerLane` returned **no `warnings`** for CC11 or CC7 on the
`.soundBank` path in any arm. The lane warning that m27 added does not fire
here — correctly, since these controllers *are* consumed; it is just that CC11
is consumed as volume.

## 4. Controls

### C0 — synthetic self-test of the measurement chain: **PASS 17/17** (2026-08-19)

`scripts/gates/_measure-c0-selftest.mjs`, run before any app was launched. Every
signal has a known ground truth, so this establishes that the chain can measure
what we are about to ask it to.

| Check | Result |
|---|---|
| `coarseF0` on a 440 Hz tone | 439.878 Hz (0.03 % error) |
| vibrato **rate**, 5.0 Hz commanded | 5.000 Hz |
| vibrato **depth**, ±50 cents commanded | ±49.82 cents (0.4 % error) |
| tremolo rate via the envelope path | 5.000 Hz |
| centroid under a −12.04 dB gain change | 1267.738 → 1267.738 Hz — **exactly invariant** |
| bandRatio under the same | 0.039263 → 0.039263 — **exactly invariant** |
| centroid across cutoff 8 kHz vs 1 kHz | 1229 → 818 Hz (**1.50×**) |
| bandRatio across the same | 0.0348 → 0.0053 (**6.59×**) |

**Two findings that change how the real measurements must be read.**

⭐ **1. PROMINENCE ALONE IS NOT A DETECTION.** A perfectly steady tone — modulation
depth ±0.0000 cents, i.e. none — still scores `modPeak` prominence **28.56**,
because prominence is peak/median of a noise floor that is not flat. Had the real
sax returned ~28 and been read as "vibrato found", that would have been a
confident wrong answer of exactly the class this session has spent the day
removing. **The operative rule is CONJUNCTIVE and is now pinned in C0:**

```js
const detected = (p, minDepth) => p.amplitude >= minDepth && p.prominence > 20;
```

For reference the genuine vibrato scored depth ±49.8 cents at prominence 1203.8 —
42× the flat trace. The two are separable, but only if depth is consulted.

⭐ **2. `bandRatio` is the sensitive timbre metric here; centroid is the blunt one.**
Against an identical filter change, bandRatio moved **6.59×** while centroid moved
only **1.50×** — centroid is dragged toward the strong low harmonics of a 1/n
series. **Q3 should therefore be decided on bandRatio, with centroid reported
alongside as corroboration.** A weak centroid movement is not evidence of "no
filter"; a flat bandRatio is much closer to being that.

### C1 — built-in `.sampler`, `expressionFilterDepth: 1.0`, CC11 127 vs 40: **FIRED** (2026-08-19)

**This is the control that makes §3 interpretable, and it fired hard.**

Identical chain to Q3 — same wire verbs, same note, same render, same analysis
window, same code path — with the instrument swapped for the built-in
`.sampler` carrying one zone (a synthesised 220 Hz, 40-harmonic sawtooth, 9 s,
16-bit) played at its root pitch so no resampling is involved.
`expressionFilterDepth: 1.0`; `expressionModDepth` deliberately left at 0 so
amplitude stays out of it.

| Arm | RMS (dBFS) | centroid (Hz) | bandRatio |
|---|---|---|---|
| CC11 = 127 | −7.946 | 2031.53 | 0.050994 |
| CC11 = 40 | −18.590 | 1166.77 | 0.008646 |

**bandRatio moved 5.898×; centroid moved 1.741×.** The predicted cutoffs
(`Model.swift:1630-1660`) are 20 kHz at CC11 = 127 and
`400 × 50^0.315 ≈ 1.37 kHz` at CC11 = 40, and the measured move is the right
size and direction for exactly that.

⭐ **C1 is also the negative control for the scalar-fit test itself.** Fitting
one gain across C1's two renders leaves a residual of **−9.75 dB** — the fit
explains almost nothing, because no scalar can undo a filter. Against Q3's
**−104.35 dB**, the two cases are separated by 95 dB. That rules out the failure
mode where `gainFit` simply reads "pure gain" for everything and Q3's number
means nothing.

Note the C1 ratio ordering, which corroborates C0's second finding on real
audio: **bandRatio 5.90× versus centroid 1.74×**, the same shape as C0's
synthetic 6.59× versus 1.50×. Centroid is the blunt instrument on both.

### C2 — authored bend vibrato on the DLS sax: **FIRED, with a caveat that became §2.3** (2026-08-19)

875 pitch-bend points at 8 ms spacing (leg D's own `bendSpacingSeconds`
default), commanding ±50 cents at 5.0 Hz on the GM sax.

| | commanded | measured |
|---|---|---|
| rate | 5.0 Hz | **5.000 Hz** ✓ |
| depth | ±50 cents | **±36.94 cents (74 %)** |
| prominence | — | 156.7 (detected) |

**The control fired**: bend bytes reach AUSampler on the `.soundBank` path, and
the f0 tracker finds a known modulation *through a DLS sample*. So a Q1 null
could not have been "the tracker cannot see modulation here."

⭐ **Its 74 % shortfall is what uncovered §2.3.** Two candidate explanations
existed and C2 alone could not separate them: 5.0 Hz sits inside the 5.400 Hz
patch LFO's main lobe (so the estimate is contaminated), *and* the hosted path
turned out to sample bend at the block rate. Chasing it with the rate sweep,
then with the alias scan, found the sample-and-hold.
The sinc model predicts 72.6 % at 5.0 Hz against 73.9 % measured — the residual
being the LFO contamination. **A control that "passes" can still be carrying a
finding; this one was.**

### C3 — built-in `.sampler`, bend centre vs max: **PASS** (2026-08-19)

Synthesised 440 Hz sine zone at root pitch, bend stepped 8192 → 16383 mid-note.

**Measured 199.97 cents against the hard-coded 200.0**
(`SamplerInstrument.swift:308`) — 0.03 cents of error. Centre window measured
440.000 Hz with ±0.000 cents of wobble; both windows steady.

This is what licenses reading Q2's 201.55 as a property of AUSampler rather
than of the measurement: the same code path returns a known 200 as 200.

## 5. What this means for the design

All three questions are answered. Below, each change is stated as *what
`docs/research/design-breath-pad.md` says now* → *what it must say instead*.

### 5.1 Q3 → the pad on the sax is a LOUDNESS-AND-PITCH device. Say so.

**Now** (§6.2): "whether it moves a filter is the plugin's decision, not ours…
we cannot honestly claim either way."
**Must say**: we measured it, and the answer is no.

> On the `.soundBank` path, CC 11 is **exactly a gain change** — measured, with
> any non-gain difference bounded at **−104 dB** — following the MIDI
> `(value/127)²` law to four decimal places. **The pad on the sax is a
> loudness-and-pitch device. It delivers no timbre at all.**

The brief's condition is met in full: **C1 fired** (bandRatio 5.90×) through the
identical chain, and **CC bytes provably arrive** (20.07 dB of level movement),
so this is a measured negative, not a failure to measure.

Concretely, in the design doc:

- §6.1's table row **"Timbre / brightness"** must be marked *built-in `.sampler`
  only*, not merely "asymmetric".
- §6.2's "we cannot honestly claim either way" must be **deleted** and replaced
  with the measurement. `MIDIControllerRouting`'s `.routed` verdict for
  `.soundBank` is still right as a *routing* statement — the byte is delivered
  and consumed — but it must not be read as "brightness might happen". The
  warning path should say what CC11 *does* do there: change loudness.
- §6.4's `vibratoAmDepth` recommendation says AM "on the built-in `.sampler`
  with `expressionFilterDepth` on… modulates brightness too". True there,
  **false on the sax** — where an AM term on CC 11 is a pure tremolo. Worth
  shipping anyway (the saxophone literature's ~10 % pressure variation is an
  amplitude effect first), but the brightness claim must be scoped.

⭐ Also worth adding, because it is the first direct confirmation: **CC 11
defaults to 127** — a no-lane render is *bit-identical* to a CC11 = 127 render.
The codebase warns about this in prose; it is now measured.

### 5.2 Q1 → CC 1 is a REAL, LINEAR vibrato control. The design does not use it, and should.

**Now**: the design reaches vibrato exclusively through the **pitch-bend lane**
(`vibratoDepthCents`, §6.1). CC 1 is not part of the pad on any path.
**Must say**: on the sound-bank path there is a second, better route.

> The stock GM sax has an always-on 5.400 Hz pitch vibrato whose **depth is
> linear in CC 1**: `depth_cents ≈ 2.42 + 0.2996 × CC1`, from ±2.4 cents at 0 to
> ±40.5 cents at 127. Rate is fixed and not controllable.

Why this matters more than a second option: **§2.3a shows the pitch-bend route
is not merely attenuated on this path but ALIASED** — at leg D's own 5.5 Hz
default it delivers 35.4 cents at 5.50 Hz *plus* 30.0 cents at 6.22 Hz, two
components beating with a 1.39 s period. The CC 1 route is immune, and not by
luck: §2.4 shows AUSampler computes pitch per sample and only reads its **MIDI
inputs** per block, so **a controller that sets a DEPTH passes through cleanly
while a controller that carries a WAVEFORM does not.** The direct evidence is
the patch's own 5.400 Hz LFO arriving at full depth (40.468 cents) with its
would-be image 159× down.

**On `.soundBank` tracks, CC 1 is not a preference — it is the only route that
delivers the vibrato that was asked for.**

Two limits the design must carry:

1. **The rate is fixed at 5.400 Hz.** The pad cannot choose a vibrato rate on
   the sax via CC 1. Leg D's bend route can, at the cost of §2.3's attenuation.
   That is a genuine trade, and the doc should present it as one.
2. ⛔ **The patch gates its own vibrato off for the first ~0.53 s**, then
   switches to full depth in ~40 ms. This **stacks** with leg D's own delayed
   vibrato ("straight for the first ~0.5 s, then blooming"). Driving CC 1 with
   leg D's delay on top means no vibrato until ~1 s in, and **notes shorter than
   ~0.6 s get none at all**. The design's note-too-short branch currently
   reasons about one vibrato-cycle's worth of length; on this path the real
   threshold is the patch's delay, which is larger.

### 5.3 Q2 → leg D's `bendRangeSemitones: 2` is correct. Delete the ⚠️.

**Now** (`BreathContour.swift:244-249`): "⚠️ **UNVERIFIED for hosted AUs.**
`AUHostRegistry` never sets `kAUSamplerProperty`'s bend range, so a hosted
AUSampler uses its own factory default (conventionally ±2, unmeasured here…)".
**Must say**:

> Measured 2026-08-19 on the stock `gs_instruments.dls` through AUSampler:
> **±2.0155 semitones**, linear to within 0.087 cents over six levels. The
> default of 2 is correct to **0.78 %** — a commanded ±12 cent vibrato lands at
> ±12.09 cents. No correction factor is needed.

The observation that `AUHostRegistry` never configures the range stays true and
is still worth stating; what changes is that the *consequence* is now known to
be negligible rather than unknown. **§6.2's item (ii) is closed.**

### 5.4 The finding the design did not ask for, and should act on first

**§2.3/§2.3a/§2.4: pitch-bend lanes are SAMPLE-AND-HELD at the render block rate
on the hosted-AU path** — 85.33 ms, i.e. an 11.719 Hz sampler with a Nyquist of
**5.86 Hz**, sitting directly under the mechanism leg D already ships.

This outranks the three questions in practical impact. What a bounce actually
delivers for an authored ±50 cent vibrato on a sound-bank track:

| authored rate | at that rate | plus an alias at | total effect |
|---|---|---|---|
| 2 Hz | 47.5 c | 9.72 Hz, 9.7 c | usable |
| **5.5 Hz (leg D's default)** | **35.4 c** | **6.22 Hz, 30.0 c** | **two vibratos beating at 1.39 s** |
| 8 Hz | 19.2 c | 3.72 Hz, **41.7 c** | mostly a 3.7 Hz wobble |
| 11 Hz | 3.2 c | 0.72 Hz, **49.8 c** | **a 0.7 Hz pitch drift at full depth** |
| 11.72 Hz | 0 | — | a static **−17.9 cent detune** |
| 14 Hz | 7.4 c | 2.28 Hz, **46.5 c** | a 2.3 Hz wobble |

A user who asks for ±12 cents at 5.5 Hz gets ±8.5 cents at 5.5 Hz **and** ±7.2
cents at 6.22 Hz beating against it. Nothing warns them; the lane is stored,
delivered and consumed — it is just sampled too slowly. That is the same shape as
the defect this whole line of work exists to remove (seven CC 11 lanes stored,
displayed and inert), one layer down and harder to see: **not inert, and not
merely attenuated, but replaced by something else.**

Three consequences to file:

1. **On `.soundBank` tracks, drive vibrato with CC 1, not the bend lane**,
   whenever the fixed 5.400 Hz rate is acceptable (§5.2). It is structurally
   immune (§2.4).
2. **Keep authored bend below ~4 Hz** on this path if the bend lane must be used
   — micro-sharpening and slow scoops are fine; vibrato is not. Above the
   5.86 Hz Nyquist, the authored rate is not what is delivered.
3. **Verify the live-vs-bounce divergence predicted in §2.4** and, if confirmed,
   treat the 4096-frame default as a bounce-fidelity bug rather than a tuning
   choice. The test is one line: `OfflineRenderer(maximumFrameCount: 512)` and
   re-measure the 11.72 Hz point — if the null moves to 93.75 Hz, confirmed.

### 5.5 What was NOT measured — stated plainly

- **Live playback was not measured at all.** Everything here is `render.bounce`.
  §2.4's live-vs-bounce claim is a *prediction with a stated mechanism*, flagged
  as such, with its falsifying test written down.
- **One sound bank, one program, one pitch, one velocity.** Tenor Sax (66) at
  D4, velocity 100. CC 11 being a pure gain is a property of *this* patch as
  rendered by AUSampler; a `.sf2` with filter-modulator routing could behave
  differently, and nothing here licenses a claim about sound banks in general.
- **CC 2 (breath) was not tested**, only CC 1, CC 7 and CC 11. If the design
  wants a second "bite" axis on the sax, whether CC 2 does anything there is
  still unknown.
- **The 5.5 Hz bend point is contaminated** by the patch's own 5.400 Hz LFO and
  is reported with that caveat rather than cleaned up.
- Velocity's effect on timbre — the obvious remaining lever for brightness on
  this patch — was not measured, and is the natural next experiment now that
  CC 11 is ruled out.

---

## 6. m28-bug — §2.4's falsifying test, RUN (2026-08-20)

§2.4 ended on a prediction it could not test, because the render block size is
not reachable from the wire. It is reachable from Swift, so the test ran there:
`Tests/DAWEngineTests/BlockRateBounceProbeTests.swift` renders the same trials
at a chosen `OfflineRenderer(maximumFrameCount:)`, and
`scripts/gates/_measure-blockfix-scan.mjs` re-analyses them with **the same
analysis library** (`_measure-dsp.mjs`) the published figures came from.

**Verdict: the prediction is CONFIRMED. The block size is the whole mechanism.**

### 6.1 The positive control first — the 4096 arm reproduces §2.3a exactly

A hand-built probe reporting "no alias at 512" is the weakest evidence in this
repo; a probe that plumbed nothing scores the same. So the 4096 arm had to
reproduce the published numbers before the 512 arm was allowed to mean anything.
It does, to the last published digit:

| commanded | published depth | **re-measured** | published image | **re-measured** |
|---|---|---|---|---|
| 2.0 Hz | 47.5 c | **47.55 c** | 9.72 Hz, 9.7 c | **9.72 Hz, 9.67 c** |
| 5.5 Hz | 35.4 c | **35.41 c** | 6.22 Hz, 30.0 c | **6.22 Hz, 30.02 c** |
| 8.0 Hz | 19.2 c | **19.22 c** | 3.72 Hz, 41.7 c | **3.72 Hz, 41.70 c** |
| 11.0 Hz | 3.2 c | **3.18 c** | 0.72 Hz, 49.8 c | **0.72 Hz, 49.81 c** |
| 11.72 Hz | 0.013 c, f0 290.687 Hz | **0.01 c, f0 290.686 Hz** | — | — |

Different language, different harness, different process — same numbers. The
instrument is sound.

### 6.2 The decisive point: the null does not shrink, it MOVES

| block | controller rate | Nyquist | depth at 11.72 Hz | mean f0 |
|---|---|---|---|---|
| 4096 | 11.719 Hz | 5.86 Hz | **0.01 c (0.0 %)** | **290.686 Hz** (−17.9 c detune) |
| 1024 | 46.875 Hz | 23.44 Hz | 43.92 c (87.8 %) | 293.716 Hz |
| **512** | **93.750 Hz** | **46.88 Hz** | **47.55 c (95.1 %)** | **293.719 Hz** |

The 11.72 Hz vibrato that a 4096-frame bounce delivers as a **static −17.9 cent
detune** is delivered at **95.1 % of its authored depth, at the authored rate**,
by a 512-frame bounce. A null becoming full depth is not something a smoother
can produce — only re-sampling can, which is the mechanism §2.4 named.

Depth across the whole band, 512 frames: **100.6 / 96.5 / 98.1 / 95.7 / 95.1 %**
at 2 / 5.5 / 8 / 11 / 11.72 Hz — matching the built-in `.sampler` control's
~49 c of 50, on the path that previously delivered 0.

### 6.3 ⭐ The image did not vanish. It went where it was predicted to go.

An absence is weak evidence. This is not an absence: at 512 frames the alias
appears in the local-maxima list at **85.74 Hz** (8 Hz arm), **82.74 Hz** (11 Hz)
and **82.02 Hz** (11.72 Hz) — exactly `|93.75 − f|` each time, the same law that
held at 4096. The sampler did not stop aliasing; **its images left the vibrato
band**.

Two independent instruments agree on their size. The zero-order-hold model says
the image sits at `A·|sinc(π(f_s − f)/f_s)|`; the analyser's own demodulator
correction says something separately. They land on the same figure:

| commanded | image at | ZOH theory | demod-corrected measurement |
|---|---|---|---|
| 2.0 Hz | 91.75 Hz | 1.09 c | **1.04 c** |
| 5.5 Hz | 88.25 Hz | 3.10 c | **3.14 c** |
| 8.0 Hz | 85.75 Hz | 4.65 c | **4.64 c** |
| 11.0 Hz | 82.75 Hz | 6.57 c | **6.47 c** |
| 11.72 Hz | 82.03 Hz | 7.04 c | **6.76 c** |

⚠️ **Stated plainly rather than laundered: the worst-case image is ~7 cents, not
zero.** It is a 7-cent pitch wobble at 82 Hz — a low-level sideband pair, not a
vibrato — against the **49.8 cents at 0.72 Hz** the same lane produced at 4096.
The defect is not "removed"; it is moved out of the band where it was audible as
the wrong musical gesture, and attenuated ~7×.

### 6.4 Why 512 and not 1024 — the data chose

1024 clears the *musical* band but does **not** clear the detector:

| block | images counted (>3 c AND >10 % of fundamental) |
|---|---|
| 4096 | **4** — at 9.72, 6.22, 3.72, 0.72 Hz (30–50 c) |
| 1024 | **4** — at 41.4, 38.9, 35.9, 35.2 Hz (5.1–12.5 c) |
| **512** | **0** |

1024 also leaves 4–12 % of authored depth on the floor, so a bounce and a live
monitor would still differ. 512 is the live buffer, so they agree by
construction. ⚠️ That last argument is a *design* argument, not a measured one:
the hardware buffer is device-dependent and user-changeable. **The measured
argument for 512 is simply that its sampler's Nyquist (46.9 Hz) sits above the
entire musical modulation band, and 1024's detector count is not zero.**

### 6.5 Method notes

- Probe: `Tests/DAWEngineTests/BlockRateBounceProbeTests.swift`, env-gated
  (`DAWPRO_BLOCK_PROBE=1`), timing copied value-for-value from
  `_measure-gm-sax-cc.mjs` (120 BPM, note on at 1.0 s, off at 7.0 s, 8 s render,
  analysis window 2.0–5.5 s, tenor sax 66 at D4, ±50 c authored every 8 ms).
- Scan: `scripts/gates/_measure-blockfix-scan.mjs`, extended to 120 Hz so the
  moved image is *found* rather than merely *missing* from a 20 Hz scan. ⚠️ A
  0.5–20 Hz scan cannot see an 85 Hz image; its silence there would have been
  evidence of nothing.

### 6.6 The CC 11 arm (P5) — the same defect, and it is worse in the ratio

T5 (`SoundBankHostingTests`) established that CC 11 shares bend's block
quantisation. Re-run across block sizes, carrier = amplitude envelope
(1000 Hz trace; ⚠️ T5's own `hop = 256` gives a 187.5 Hz envelope whose Nyquist
is *exactly* the 512-frame block rate, so that hop cannot measure this arm):

| commanded | 4096: depth / image ratio | 1024 | **512: depth / image ratio** |
|---|---|---|---|
| 2.0 Hz | 86.1 % / **0.203** | 90.1 % / 0.036 | **90.4 % / 0.007** |
| 5.5 Hz | 60.8 % / **0.865** | 85.5 % / 0.112 | **87.7 % / 0.022** |
| 8.0 Hz | 34.7 % / **2.173** | 84.0 % / 0.173 | **87.7 % / 0.036** |
| 11.0 Hz | 5.1 % / **15.559** | 79.5 % / 0.265 | **84.8 % / 0.054** |
| 11.72 Hz | 0.08 % / — | 78.1 % / 0.291 | **85.3 % / 0.059** |

At 4096 an authored 8 Hz tremolo is delivered with its **3.72 Hz alias twice as
loud as the tremolo itself**, and an 11 Hz tremolo is delivered as a 0.72 Hz
swell **15.6× louder** than anything at 11 Hz. At 512 every image is ≤ 6 % of
the commanded component and depth is restored to 85–90 % across the band.

**Consequence for P5:** the physiological tremor band (4–8 Hz, §10.1) is
delivered essentially intact at 512 — 87.7 % of depth at both 5.5 and 8 Hz with
image ratios of 0.022 and 0.036. The suppression P5 applies on hosted-AU tracks
was a workaround for the block rate, and the measurement that motivated it no
longer holds once the default is 512. ⚠️ The lift is conditioned on **the
default** changing, not on any one call site: anywhere a hosted-AU tremor can
still be rendered at 4096, the aliasing returns.

## 7. The fix (m28-bug, 2026-08-20)

### 7.1 What changed

| | before | after |
|---|---|---|
| `OfflineRenderer` default block | literal `4_096` | `RenderBlockSize.offlineFrames` = **512** |
| `EffortField.hostedAUOfflineModulationSamplingHz` | literal `48_000.0 / 4_096.0` | **derived** from the same constant ⇒ 93.75 Hz |
| `bendModulationNyquistHz` | literal `5.86` | derived ⇒ **46.875 Hz** |
| tremor / vibrato suppression | **unconditional** on hosted AUs | gated on `modulationAliasesUnacceptably` (image ratio > 0.25) |

New file `Sources/DAWCore/RenderBlockSize.swift` is the single home. ⚠️ **The
constant had to move with the block, and that was not optional.** Leaving it at
4096 would have left every capability warning describing an engine that no longer
exists. Worse, moving the constant *without* gating the suppression would have
printed "an extra copy at 85.75 Hz at 0.09x its depth … would need a rate at or
below 18.75 Hz" and then suppressed a 4.565 Hz tremor anyway — **a sentence
contradicting its own action**, which is the exact failure class this line of
work exists to end.

⚠️ **`AUHostRegistry`'s `maximumFramesToRender` (8192) was NOT touched.** That is
a CAPACITY — the largest block a hosted AU is told it may be asked for. This is
the call size. Different numbers.

### 7.2 Cost, measured

8 hosted GM sound-bank tracks, dense parts, bend lanes on every one (the
block-sensitive case), 120 s of audio, 3 runs each, `render()` only —
`prepareAudioUnits` is excluded because a GM bank load costs seconds and would
swamp the effect entirely:

| block | mean | spread | vs realtime |
|---|---|---|---|
| 4096 | 0.449 s | 0.446–0.452 | 267× |
| 1024 | 0.514 s | 0.512–0.516 | 234× |
| **512** | **0.587 s** | 0.586–0.588 | **204×** |

**+0.138 s on a two-minute eight-track bounce — a 1.31× render.** Paid.

### 7.3 P5's tremor suppression: LIFTED for the physiological band

The question P5 left open. At 4096 the rate ceiling (image 12 dB down) was
**2.34 Hz**, below §10.1's whole 4–8 Hz band — so P5 suppressed rather than
retune a tremor out of the band it is named for. At 512 the ceiling is
**18.75 Hz** and the band sits entirely under it, with rendered confirmation:
87.7 % of authored depth at both 5.5 and 8 Hz, image ratios 0.022 and 0.036
(§6.6).

⛔ **The gate is not deleted, and should not be.** `tremorRateHz` is authorable
to 20 Hz, which is still above 18.75 — so the suppression path and its warning
remain live and remain tested, now on the rate rather than on the instrument.

The same lift applies to **bend vibrato**, whose gate was the tremor gate's twin
one line away: leg D's 5.5 Hz vibrato has an image ratio of 0.062 at 93.75 Hz, so
it is now written on the GM sax instead of refused. That is the user-visible
headline — *the sax gets its vibrato in a bounce.*

### 7.4 Every test whose expectation moved, and why

Four moved. None was loosened to pass; each measured something that is now
genuinely different, and each kept a positive control.

| test | what moved | why |
|---|---|---|
| `AutomationFXParamTests` — gainLinear staircase | 22 steps → **186**; `quantum` now derives from `RenderBlockSize` | Effect-param automation is evaluated at each quantum start, so it is now **8× finer**. The staircase is unchanged in kind: intra-quantum spread still exactly **0.0**, max error 7.4e-09. This is the automation-resolution half of the fix, and it moves rendered bytes on every automated bounce. |
| `SoundBankHostingTests` T5 | pinned to an explicit 4096 block, plus a new shipping-block arm | Its four ZOH ratios are FACTS ABOUT 4096. Re-pointing them at whatever ships would have left a measurement asserting nothing while still looking like one. The new arm measures the shipping block: image/commanded **0.032** where 4096 gave **2.14**. |
| `ControllerLaneTests` — bend vibrato on a sound-bank track | "suppressed, reported 0" → **"written and reported"** | The fix's user-visible point. Leg D's 5.5 Hz vibrato now lands on the GM sax; the assertion flipped from `deviation < 300` to `> 300` (vibrato-sized, not sharpening-sized). |
| `ControllerLaneTests` — tremor suppression | 5.5 Hz suppressed → 5.5 Hz **written**; suppression re-tested at **19.5 Hz** | The rule changed from "hosted AU ⇒ no tremor" to "above the ceiling ⇒ no tremor". Both sides are now pinned, so the machinery cannot rot in either direction. |

Plus `BreathPadDeterminismTests`, whose two ceiling tests were re-pinned to the
**literal** `48_000.0 / 4_096.0` for the same reason T5 was: they check a formula
against a measurement, and the measurement was taken at that block.

⚠️ **`AUPrepareRenegotiationStressTests` also failed in the full run and is NOT
this change** — it is a known load flake (it passes in isolation, verified) and
the brief lists it as such.

### 7.5 What is still true, and what this does not fix

- ⛔ **The sample-and-hold is not gone.** AUSampler still reads MIDI once per
  render call; the images still exist, at `|93.75 − f|`, at ~1–7 ¢. This raises
  the ceiling by 8×, it does not remove it. Authoring a 30 Hz pitch modulation on
  a hosted AU will still alias, and the gate still says so.
- ⚠️ **Live playback is still not measured by any gate here.** P6 measured
  `quantumFrames = 512` once, on one machine, on one device. The HAL buffer is a
  user setting; the two paths agreeing is a property of this rig, not a
  guarantee. The ceiling remains computed from OUR block, which is the half we
  control.
- ⚠️ **The suppression gate is an AUTHORING-time decision, and it now reads the
  OFFLINE block only.** `modulationAliasesUnacceptably` decides once, when the
  lane is written; both paths then consume the same lane. Before this change,
  unconditional suppression protected the live path by accident. It no longer
  does, so on a rig with a HAL buffer **larger than 512** the monitor samples the
  lane more coarsely than the bounce — the reverse of the bug we just fixed, and
  the one direction where "the export is correct" is the consolation.
  **The arithmetic says do not act on this.** At 1024 frames live the ceiling is
  9.375 Hz: a 5.5 Hz vibrato is ratio 0.13 and a 4.565 Hz tremor 0.108, both
  clear. Even at 2048 the image from a 5.5 Hz modulation lands near 17.9 Hz —
  outside the vibrato band entirely, so the artefact is a faint sideband rather
  than the wrong gesture, nothing like the 0.72 Hz beat that 4096 produced. On
  any rig with a buffer **≤ 512** — including every default — our block is the
  coarser-or-equal one and the gate is conservative for both paths. Revisit only
  if a device-buffer reading becomes reachable from `DAWCore` without dragging
  AVFoundation across the boundary.
- **Nothing here says anything about third-party AUv2/AUv3 plugins.** Every
  measurement is Apple's AUSampler with the stock `gs_instruments.dls`. A plugin
  that interpolates its own controller input would never have shown this defect;
  one that decimates harder could still alias at 512.
