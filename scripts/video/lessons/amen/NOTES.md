# The Amen break, programmed by hand — rebuild notes

Every number this film says, where it came from, and the command that produced
it. Nothing here was copied out of the shipped film's description; the shipped
figures (53 notes; humanize max 7.81 ms, mean 3.54 ms) were treated as prior art
and re-derived from scratch. **The note count came out at 53 independently** —
built from `video-facts-history.md` §3's structural description, not steered
toward the old figure — and **the humanize figures did not reproduce**, because
they belong to a different seed over a different number of notes.

⛔ **The 1969 recording is never touched.** "Amen, Brother" (The Winstons, 1969)
is a sound recording still in copyright in the US into the 2060s. Nothing in
this build reads, downloads or analyses that record. Every sound in the film is
one of 53 MIDI notes typed into DAW Pro and played by the GeneralUser-GS General
MIDI drum kit. That limit is the lesson's spine, not a footnote, and it has its
own chapter.

## The film as built

`out/L9v2.mp4` — **811.9 s (13:32)**, 45,682,256 bytes, 1920×1080 h264 / 48 kHz
AAC stereo.
**−16.1 LUFS integrated, −1.1 dBTP** (measured by `verify.py`, re-measured by
hand with `ffmpeg -hide_banner … ebur128=peak=true`). **NOT finalized, NOT
published**; the shipped `~/Movies/DAW Pro Lesson 9 - The Amen Break.mp4` is
untouched, and the spec's `filename` is deliberately different
(`… (rebuild)`) so even a stray `--finalize` could not overwrite it.

653.9 s of explanation against 151.0 s of demonstration, across 35 segments.
Both figures are sums of `out/segments/*.mp4` durations read with ffprobe, and
with the 4 s intro and 3 s outro they add to 811.9 s — the film's own length
(ffprobe on the file: 811.933 s; the 43 ms gap is container rounding).

⚠ **−1.1 dBTP is 0.4 dB above the −1.5 the brief states.** It is inside house
practice rather than an exception: of the five shipped rebuilds, mono-bass is
−1.0 and beethoven-128 is −1.2. Measured across all nine finished films the
range is −16.1 to −17.2 LUFS (comma is the outlier at −14.6) and −1.0 to
−1.5 dBTP. Flagging it rather than quietly rounding.

## Chapters, computed from segment durations

⚠ `timeline.json` has gone stale across rebuilds three times, so these are
summed from `out/segments/*.mp4` with ffprobe in the order of `_all.txt`, which
is the concat list the deliverable was actually built from.

```
0:00  Intro
0:04  What the Amen break is
0:41  Four words, in plain English
1:16  The record: The Winstons, 1969
2:00  Why we program it instead of sampling it
2:45  The sixteenth-note grid
3:19  The straight skeleton
3:54  Velocity is not decibels
4:49  Ghost notes
5:52  Where the ghost notes are
6:50  Bar three: the snare arrives late
7:51  Bar four: the empty downbeat
8:26  All fifty-three notes
9:08  Off the grid, measured
9:53  How much of it you can hear
10:52 What a loudness meter cannot see
11:30 One hundred and seventy: jungle
12:27 The controls
12:56 What to take away
13:28 Outro
```

## How to rebuild the whole thing

```bash
cd scripts/video/lessons/amen
V=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin

# 0. the velocity ladder the material's velocities are CHOSEN from  (staging 17695)
DAW_CONTROL_PORT=17695 node probe3.mjs

# 1. every render + the humanize read-back                          (staging 17695)
DAW_CONTROL_PORT=17695 SESSION_SHOTS=$PWD/shots SESSION_BURSTS=$PWD/bursts node shoot.mjs

# 2. the stills, framed separately so a re-frame costs no renders
DAW_CONTROL_PORT=17695 SESSION_SHOTS=$PWD/shots node stills.mjs

# 2b. only if material.mjs gained a COUNTS key after the renders: re-derive the
#     counts block in media/material.json WITHOUT re-rendering. Derives from
#     material.mjs; never types a number in. A full shoot.mjs run makes it moot.
node recount.mjs

# 3. every measurement  ->  MEASUREMENTS.json + the A/B wavs
$V/python measure.py

# 4. the three matplotlib charts  ->  shots/chart-*.png
$V/python charts.py

# 5. the two manim scenes + their audio beds  ->  bursts/ + audio/bed-*.wav
$V/python bursts.py                # --audio-only re-lays the beds, no re-render

# 6. the spec, then the film
$V/python spec.py
OMLX_BASE=http://127.0.0.1:$PORT $V/python ../../shortsmith.py L9v2.json --out-dir $PWD/out
```

⛔ **Pick your own speech-server port.** This build used **8417**, started as
pid 39515 and killed pid-exact; the port was then proven free with
`lsof -nP -iTCP:8417 -sTCP:LISTEN` printing nothing and `ps -p` reporting the
pid gone. Never kill a server on a port you did not start: the port tells you
*what* it is, never *whose*.

## The material

**136 BPM**, so one beat is 441.176 ms and **one sixteenth note is
110.294 ms** — the ruler the whole film measures against. 4 bars, 53 notes,
across three tracks (Kick / Snare / Cymbals) so per-hit onset and level
measurement lands on a clean stem instead of on a mix with continuous ride
eighths under it.

| part | count |
|---|---|
| kick | 7 |
| snare accents | 9 |
| snare ghosts | 5 |
| ride cymbal | 31 |
| crash | 1 |
| **total** | **53** |

The grid is written from `video-facts-history.md` §3's structural description:
bars 1–2 straight, **bar 3's beat-four snare pushed one sixteenth late**, **bar
4 with no kick on the downbeat** and a crash on the "and" of 3. ⚠ The fact
sheet flags — and the film says on screen and out loud — that this is the
**skeleton producers program, not a sample-exact transcription**; Ethan Hein's
point that "hardly any of [Coleman's] hits are exactly where they are supposed
to be" is stated in chapter 11, not buried.

Facts stated: 1969, The Winstons, B-side, Gregory Coleman, ~7 s, four bars,
"commonly given as 136–140 BPM" (as a range, because it is a human playing), the
royalties history, the 2015 fundraiser at ~£18,000 described as *a gift, not a
settlement*. **The National Recording Registry item was NOT used** — the fact
sheet marks it UNVERIFIED with a date that smells garbled, so it is cut. The
film says "very likely the most sampled", never "is".

## Everything measured

All of it is in `MEASUREMENTS.json`, written by `measure.py` from the renders
`shoot.mjs` made. `spec.py` injects every card figure from that file and
**asserts every spoken figure against it** (`check()`), so a narration that
drifted from a measurement refuses to build.

### The velocity law — predicted, then measured

Predicted before any render: a General MIDI bank scales note **amplitude** with
`(v/127)²`, i.e. **40·log₁₀(v/127)** dB. Measured across 17 velocities per drum:

| drum | worst error vs the prediction |
|---|---|
| ride | **±0.03 dB**, all 17 velocities |
| snare | **±0.02 dB** at 14 of 17 |
| kick | ±0.09 dB, with a −0.7 dB dip around v60–90 |
| closed hat | **−7.89 dB at v10**, closing steadily to 0 at v127 |

⭐ **The law is not universal and the film says so.** The closed hat plainly
follows a different curve. And the snare has a **velocity layer covering
v55–v70 that sits +4.67 dB off the curve** — the bank switching to a *different
recording* of the drum. That is on screen as a shaded band on
`chart-velocity.png`.

**Ghost notes: predicted −13.70 dB below the accents, measured −13.72 dB.**
(velocity 50 against 110; ghost peak −23.88 dBFS, accent −10.17 dBFS.)

### The timing

`clip.humanize` at `timingBeats: 0.02` (±8.82 ms), `velocityRange: 0`,
`seed: 20260906`, applied to all three clips of the two-pass loop.

| | |
|---|---|
| notes | **106** |
| largest \|shift\| | **8.60 ms** (7.8 % of a sixteenth) |
| mean \|shift\| | **4.65 ms** (4.2 %) |
| project vs audio | agree to **0.50 ms** |

Shifts were **read back off the project** with `clip.getNotes` (before and
after) and then **found again in the rendered audio** by onset detection on the
per-drum stems. Per stem: kick 0.019 ms, snare 0.495 ms, cymbals 0.499 ms.

The drag demo: **asked for 28 ms, cross-correlated back out of the two snare
stems at 28.0 ms.**

### One quantity, four demos

⭐ The strongest thing in the film, and it was not in the plan — it fell out of
computing one comparable number for every pair. "Difference level" is the RMS of
(A − B) against A's own RMS:

| demo | signal changed | integrated loudness changed |
|---|---|---|
| ghost notes added | **−20.5 dB** | +0.0 LU |
| bar 4 vs a repeat | −10.4 dB | −0.2 LU |
| snare dragged 28 ms | +2.6 dB | +0.1 LU |
| humanised (≤8.6 ms) | **+2.9 dB** | **+0.0 LU** |

Moving every hit by a few milliseconds changes **more of the signal** than
adding the ghost notes does, and a loudness meter reads zero for both. That is
chapter 14's whole argument, and it is measured rather than asserted.

## ⭐ The audibility fault, and what was done about it

**The brief's warning:** a 3.5 ms timing shift is near the edge of audibility,
and the user cannot hear subtle A/Bs on a laptop.

**What was measured first, and what it forced.** The first material had ghost
notes at velocity 30 with the ride at 80. The attention marker found **zero
listen windows** — the short-time level of the two renders never differed by
6 dB for as long as 20 ms, because the ghosts sat 13 dB *under* the ride. The
chapter's entire demonstration was inaudible and every gate was green.

Three treatments, in the house standard's order of preference:

1. **The source material was fixed, not the claim.** Ghosts up to velocity 50,
   ride down from 80/96 to 62/74, cymbal track from 0.8 to 0.55. Result: **6
   listen windows, peak short-time difference 22.44 dB.** A second candidate
   (velocity 55) was measured and *also* rejected — it landed inside the snare's
   sample-layer band, so the prediction and the render disagreed by 4.67 dB.
   Velocity 50 is on the curve, which is why the film can predict −13.70 and
   then measure −13.72.
2. **The timing is carried visually and honestly.** `anim_shift.py` puts the
   real humanise (largest 8.60 ms) and a deliberately exaggerated 28 ms drag on
   **the same axis at the same scale**, with a real-time playhead. The film says
   in as many words that on laptop speakers you will probably not hear the real
   one on its own, that this is the size of the thing rather than the viewer's
   ears or speakers, and that the exaggerated version is *"a magnifying glass,
   not a better version"*.
3. **The `chart-audibility` figures are stated out loud**, including the one
   that undercuts the drama: averaged over the whole loop the ghost notes move
   the level by 0.04 dB, and the film says the average is the *wrong measure*
   because ghosts are brief.

The A/B halves are honest about level: `normalize: false` on every A/B stage,
with **one shared static gain per pair** set from the louder half so nothing
clips (+8.05 dB ghosts, +7.24 dB bar 3, +6.47 dB humanise, +6.69 dB tempo).

## The attention markers

Two, both with a real-time playhead:

- `anim_ghosts.py` — short-time level of the plain vs ghosted render. **The
  shaded windows are derived**, never chosen by eye: every window where the two
  differ by more than 6 dB, gaps under 60 ms merged, anything under 20 ms
  dropped. ⭐ **It produced 6 windows and the pattern has exactly 6 ghost notes.**
  That match is a control, and the film states it as one.
- `anim_shift.py` — every hit's measured distance from the grid against time,
  humanise then drag.

Both scenes **print their own sweep offsets** and `bursts.py` builds the audio
bed from those offsets, so `run_time` and the audio cannot drift apart.

## ⚠ Two probes that lied, both caught by a positive control

### 1. `instrument.probeLiveness` reports two of four drums as silent

Probing the GeneralUser-GS kit, snare (38) and ride (51) gave clean velocity
ladders while **kick (36) and closed hat (42) came back at exactly −120.00 dB at
every one of eight velocities.** A uniform floor across every unit is the
signature of a probe that never measured.

`probe2.mjs` rendered the same six pitches for real and measured them:

| pitch | probeLiveness | real render, peak |
|---|---|---|
| 36 kick | −120.00 dB | **−10.17 dBFS** |
| 38 snare | ladder | −10.18 dBFS |
| 42 closed hat | −120.00 dB | **−12.13 dBFS** |
| 46 open hat | — | −13.64 dBFS |
| 51 ride | ladder | −14.12 dBFS |
| 49 crash | — | −10.84 dBFS |

All six sound loudly. **The tool is wrong on this instrument for at least two
GM percussion keys.** The mechanism was not chased (it is out of this task's
scope) but the disagreement is reproducible with `probe2.mjs`, and nothing in
this film uses `probeLiveness` — the velocity law comes from `probe3.mjs`, which
renders and measures.

### 2. My own onset detector was wrong on the one stem that could hide it

The first version took the first sample in a window crossing 20 % of the
window's peak. When the *previous* hit is still ringing above that fraction it
fires at sample zero and reports an onset half a window early. Kick and snare
(sparse) agreed with the project to under 3 ms; the ride (continuous eighths,
always ringing) came back with a **median onset −44 ms off** and six hits wrong
by up to 47 ms. Same code, same return value, no error anywhere.

Rewritten to look for the largest **rise** in a short-time energy envelope — a
decaying tail has no rise. Agreement went from 40.4 ms to **0.50 ms**.

⭐ The shape worth keeping: **three of four stems agreed, and that is exactly
what made the fourth easy to dismiss.**

### 3. A contradiction chased to the end rather than rounded off

Adding 10 ghost notes made the render **0.70 LUFS quieter** while its broadband
RMS went **up 0.11 dB**. Two instruments disagreeing is the signal. The
hypothesis was same-key voice stealing — a ghost cutting the previous accent's
ring — and `probe4.mjs` tested it with a control: one accent alone (A), accent
plus a quiet hit on the *same* key 331 ms later (B), and on a *different* key
(C). Measured over the window after the second hit: A −66.49 dB, B −39.19 dB,
C −40.64 dB. **B is not quieter than C, so nothing is being cut. Hypothesis
refuted.** It is BS.1770 gating: quiet ghosts bring previously-gated 400 ms
blocks in below the average. The effect disappeared at the final velocities and
is not in the film; it is here because the reasoning is the useful part.

## Things found by LOOKING, after every gate was already green

Eight checks passed on a film with each of these in it.

### 1. ⭐⭐ Two manim beds shipped at +3.6 LUFS and the loudness gate said ok

`measure.py` wrote the A/B wavs with `sf.write(...)`, which **defaults a .wav to
PCM_16**. `bursts.py` read them back with scipy, which returns the file's own
dtype — int16 — and cast to float32 without dividing. The beds were written at
**±27570 instead of ±0.84, about +89 dB.**

The film came out at **−23.4 LUFS**, 6.7 LU under target, with the loudness
gate, the A/B separation gate and the content gate **all green**. It was found
by measuring every `out/segments/*-mux.mp4` individually and seeing two at
**+3.6 LUFS** against a film whose talk segments were all −16.4.

Both ends fixed: `subtype="FLOAT"` on the write, dtype-aware scaling on the
read, **plus a hard refusal in `lay()` if any input peaks over full scale** — a
documented trap with no gate is not fixed.

### 2. A card was on screen while the words describing the chart were spoken

`12-humanize` had shots `[chart-humanize, card 9]` with `holdLast`, so the
timer is `each = total/2` and shot[1] owns the second half — which is where
*"this chart is every one of those one hundred and six hits"* falls (at 9:26).
The chart was on screen for the first half and the card for the words that read
it. Reordered to `[9, CH_HUM]` and **verified in pixels** by pulling the frame
at t=570 s.

### 3. Every drum-grid crop letterboxed into a thin strip

One crop, 3.75:1, was used for every clip. `assemble.py` letterboxes to fit, so
a one-bar clip photographed as a sliver of picture floating in a mostly black
16:9 frame — correct content, unreadably small. Found by pulling the frame at
t=428 s. The crop is now **sized to the clip**: lane names plus exactly as many
bars as the clip has, which puts a one-bar grid at roughly 1516×1080.

### 4. ⭐⭐ Two narration claims contradicted by the picture they describe

Both read perfectly plausibly and both are false against the frame:

- **09-bar3** said the displaced hit was *"the one that no longer lines up with
  the ride cymbal above it"*. The **ghost note at step 7 also fails to line up**,
  so the sentence points at two things on screen. Now: *"look at the last snare
  in the bar: it now sits between two ride cymbals instead of directly
  underneath one."*
- **10-bar4** said the crash *"sits between the ride hits rather than on one"*.
  The crash is at step 10, an eighth-note position — **exactly where a ride
  would be**, because it replaces one. The opposite of what is drawn. Now:
  *"the crash has taken over the slot where a ride cymbal would otherwise have
  been."*

### 5. ⭐⭐ "DAW Crow", at an aggregate similarity of 0.923

`12-humanize` take 1 said **"DAW Crow has a humanize command"** and **"a player
has a field"** for "a feel". Both passed: an aggregate cannot gate a two-word
substring. That stage now carries `brandCheck="DAW Pro"` and a
`["has a feel"]` factCheck, so the gate rejects the take instead of a reader
catching it. Take 2 passed at 0.98 with both probes PRESENT.

### 6. "The alpha aside" — an ambiguity, removed rather than argued

`02-history` scripted *"The A side was a song called Color Him Father"* and
Whisper wrote *"The alpha aside"*. There is no way from a transcript to tell a
speech fault from a transcription fault on a phrase that hard. It was also
jargon, which this lesson's own opening rule forbids. Rewritten to *"The song
they were promoting was called Color Him Father"* — the re-take scored 1.00.

### 7. A `str.replace` that silently did nothing

The 02-history edit above was applied with a Python `str.replace` whose source
string had different line wrapping from the file. **It matched nothing, wrote
the file unchanged, and the build cheerfully reported `02-history unchanged,
kept`.** Caught by grepping for both the old and the new text afterwards. The
re-do asserts `s.count(old) == 1` before writing.

### 8. A chart label that was off by a factor of two

`chart-humanize.png`'s red line is at 55.15 ms and was labelled *"the nearest
wrong step"*, with narration calling it *"where the next grid position would
be"*. It is **half** a sixteenth — the point past which a hit is closer to the
wrong step than to its own. Both the label and the narration now say that.

### 9. ⭐⭐ A `check()` rigged with a `+ 1`, and a count the film got wrong

The film says the pattern has **five** ghost notes (stage 11, card 5) and, of
the ghost A/B, that there are **six** listen windows, "which is exactly the
number of ghost notes". Both are true and they are about **different renders**,
and the film never said so. The ghost A/B (`s3-skeleton` vs `s4-ghosts`) is
built from `ghostPlain` — bars 1-2 repeated — which carries six ghosts; the
real four-bar pattern carries five, because bar 4 trades its second ghost for
the displaced accent.

The assertion meant to catch exactly this read

```python
check(6, C["snareGhost"] + 1, 0, "the ghost count per four bars")
```

`5 + 1 == 6`, so it passed **by construction**. A gate that has been bent to
fit is worse than no gate: it reports the thing it was silenced about. Now
`material.mjs` exports `ghostDemo` (derived from `ghostPlain`, never typed),
and the two counts are checked separately and honestly:

```python
check(6, C["ghostDemo"],   0, "ghosts in the render the chart is made from")
check(5, C["snareGhost"],  0, "ghosts in the full four-bar pattern")
```

Positive-controlled: flipping the first to `check(7, …)` makes `spec.py` exit
with `SPEC REFUSES TO BUILD — … the narration says 7 but MEASUREMENTS.json says
6.0000`. Stages `08-marker` and `16-controls` were re-recorded to say *"in this
four bar excerpt"* / *"in that excerpt"* (takes 1, sim 0.99 and 1.00), and the
build report's transcript of the shipped audio contains the new wording.

### 10. ⭐ The tempo A/B was cut mid-hit, at −3.9 dB of its own peak

Stage 15 played 10.0 s of each tempo. Measured on the sources: 10.0 s is 5.667
bars at 136 BPM and 7.083 at 170 — both mid-bar, and at 136 the cut fell 74 ms
after a kick-plus-ride, chopping it at **−3.9 dB of the file's peak**. A round
number in seconds is not a musical length.

`4 × 240/136 = 7.0588 s` is exactly **4 bars at 136 and exactly 5 bars at 170**,
so both halves end on a downbeat. Verified on the deliverable's own segments:
both are 7.059 s and their last 60 ms sit at **−42.3 dB** and **−56.4 dB** of
their own peaks. As a bonus the demo now shows the point directly — the same
duration holds one more bar at the faster tempo.

### 11. ⭐⭐ A prose warning is not a gate: three chart footnotes ran under the burned-in meter

`charts.py`'s `save()` has carried this comment since the first build:

> ⚠ keep footnotes clear of x≈0.72: the film burns a level meter into the
> bottom-RIGHT corner AFTER assembly and it eats text under it.

Nothing enforced it. Measured with matplotlib's own renderer, the velocity
footnote **in the previous build of this rebuild** ran to **x = 1695** in a
1920 px frame — the meter sat on its last third — and `chart-audibility`'s ran
to **x = 1471**. Both were in a build that passed 8/8.

⚠ "Previous build of this rebuild" is meant literally: the **published**
`~/Movies/DAW Pro Lesson 9 - The Amen Break.mp4` is a different, 154.6 s film
that contains no velocity chart at all, and it is untouched.

I found the first one only by looking at a frame; then I wrote the gate the
comment had been standing in for. `save()` now measures the drawn text extent
after `savefig` (the extent needs a renderer, which only exists once something
has drawn) and refuses past `0.72 × width`. Two positive controls: padding the
footnote made it refuse at `x=3771`, and switching the limit from the frame
edge to the meter keep-out made `chart-audibility` refuse on **text that had
already been through a green build unchanged** — the gate found a defect I had
not gone looking for.
Footnotes are now two short lines; all three were re-rendered and looked at,
and the corrected velocity chart was confirmed in the deliverable at t = 250 s.

### 12. The kick has a velocity dip of its own, and the chart did not say so

The shaded band on `chart-velocity` is labelled as the **snare's** sample-layer
switch (v55-70, +4.67 dB). The kick visibly departs in roughly the same region
and nothing mentioned it. Measured against its own v127-aligned prediction the
kick dips **0.68 dB over v60-90** — a different span from the snare's, so the
footnote says the measured span rather than "the same band". Computed in
`charts.py` from `MEASUREMENTS.json`, not typed in.

### 13. ⭐ The same wrong count, a third time, in the manim scene — found in a frame

The ghost chart's on-screen subtitle read *"the same take plus **five** quiet
snare hits **per two bars**"*, and it is wrong on both halves: the demo carries
**three** ghosts per two bars and **six** over the four-bar excerpt. Five is the
count in a different render. That makes three separate places stating this
count three different ways, of which two were wrong — the film narration, the
card, and this label — after I had already "fixed" the count once.

The lesson is the fix, not the defect: the number is now interpolated from
`MEASUREMENTS.json` in `anim_ghosts.py` rather than typed, which is what the
other two places already did. Anything typed twice will eventually disagree.
Re-rendered, rebuilt, and confirmed in the deliverable's pixels at t = 370 s:
*"the same take plus 6 quiet snare hits over four bars"*.

Note what did **not** catch it: this label is inside a manim video burst, so it
is not in any narration script, not in `MEASUREMENTS.json`, and not covered by
`check()`, the factCheck probes, or the transcribe-back gate. It is only
visible to someone pulling a frame and reading it.

### 14. Cosmetic, not fixed

- The app's top-right badge reads **"MCP 17695"** in every screen capture,
  which discloses the staging port. It is in every rebuild in this tree and
  changing it is an app-side decision, not a film one.
- `12-humanize`'s final take inserts one stray word: *"and to measure it"* for
  *"and measure it"*. Grammatically odd, semantically harmless, changes no
  claim. Left rather than spending another take round; recorded here because the
  standard is to say what was measured.
- `shortsmith.py` prints `⚠ 811.9s is OVER the 60 s Shorts limit` on every
  lesson. It is a Shorts check firing on a long-form film.
- `08-marker`'s transcript comes back as *"That matches the check"* where the
  script says *"That match is the check"*. The two are homophones; a transcript
  cannot separate a speech fault from a transcription fault here, and both
  readings are grammatical and carry the same claim. Sim 0.99. Recorded, not
  chased.

## Gates, each with its control

`verify.py` ran **8 checks, all ok** (counted: `grep -c '^  \[  ok  \]'` on the build log returns 8). The rows below that follow it are checks I ran myself, listed separately so the eight are not inflated.

| gate | result | its control |
|---|---|---|
| narration content | **18/18 passed**; sims 0.96–1.00, takes 1–3 | every take transcribed back and word-diffed against the script |
| brand substring | present in **00-open**, **04-grid**, **12-humanize** and **17-close** | transcribed off the DELIVERABLE at 28–42 s and 794–808 s, both `True`; **negative control** — a music-only window at 335 s returns `False` |
| streams | h264 1920×1080 yuv420p 30/1, aac 48 kHz stereo | — |
| a/v drift | 11.3 ms | under one frame at 30 fps |
| distinct frames | 5/5 pairs differ, max 18.28, min 11.58 | noise floor 2.0; **frame vs itself = 0.00** |
| audio present | all 4 sample points | — |
| loudness | −16.1 LUFS / −1.1 dBTP | re-measured by hand with `-hide_banner` |
| A/B separation | 07 src +0.00 → film +0.20 LU (content −19.9 dB); 09 src +0.20 → +0.20; 15 src −0.80 → −1.00 (content +3.4 dB) | compares the film's delta against the SOURCE wavs' delta |
| content transcribe-back | best stage **0.30** vs worst control **0.02** | **14.1× separation** over 6 blind windows |
| human look | **19 images** inspected at full size, of which **9** are frames pulled from a finished film (t=20, 194, 250, 370, 428, 430, 487, 567, 570 s) plus 2 bottom-strip crops checking the meter keep-out (t=370, 660). Frames at t=360, 705, 720 were pulled and hashed but **never viewed**, so they are not counted | — |
| listen-window derivation | 6 windows | the **ghost demo** (`ghostPlain`) has exactly **6** ghost notes — `check(6, C["ghostDemo"])`, positive-controlled by flipping it to 7 and watching `spec.py` refuse. The full four-bar pattern has **5**, checked separately; the old assertion hid the difference behind a `+ 1` |
| shot duplication | `md5 -q shots/*.png \| sort \| uniq -d` empty | positive-controlled: it *did* report 3 dupes on the previous run, all stale files |
| chart footnote keep-out | all 3 charts clear of `0.72 × width` | new gate in `charts.py`'s `save()`, measured with matplotlib's renderer. **Two positive controls**: a padded footnote refuses at `x=3771`, and the gate refused `chart-audibility`'s text at `x=1471`, unchanged from the previous green build |
| per-segment loudness | all 33 muxed segments between −16.9 and −14.0 LUFS | this sweep is what caught the +89 dB bed; a single film-level number cannot see one bad segment |
| A/B musical cut | swept **all 15** demo segments (`*-ab*-mux`, `*-play-mux`): worst tail is the tempo pair at **−42.3 dB** of its own peak, the rest −56 dB to −240 dB | the rejected 10.0 s tempo cut measured **−3.9 dB** of peak on the same probe, i.e. mid-hit — so the probe demonstrably separates a chopped cut from a clean one |
| gitignore | heavy dirs ignored | positive control both ways — `spec.py`/`NOTES.md` confirmed **NOT** ignored |

## Choices made without asking

- **Length.** 2845 words over 18 stages, 13:32. The directive says there is no
  time budget and explainability is the goal, so nothing was trimmed for length.
  Four chapters (01 vocabulary, 02 history, 03 copyright, 16 controls) explain
  and demonstrate nothing.
- **A fourth, muted, photography-only track.** The three real tracks are Kick /
  Snare / Cymbals, which is what every wav is rendered from. A muted "Amen
  Break" track carries bar-sliced copies of the same 53 notes so one drum grid
  can show kick, snare and cymbals as named lanes together. It is never
  rendered.
- **The step sequencer over the piano roll** for every pattern picture. Its
  lanes are *named* ("Acoustic Snare", "Bass Drum 1"), which a novice can read;
  a piano roll of pitches 36/38/51 is not. Decided from the pixels.
- **`theme="remix"`**, matching the shipped film's row in `PROGRAM.md`, so the
  rebuild is the same episode rather than a different-looking one.
- **The tempo chapter names what our demo cannot do.** Speeding up MIDI changes
  only timing; jungle producers sped up *tape*, which raised the pitch too. The
  film says so explicitly rather than letting the demo stand in for the thing it
  is not.

## Traps hit during this build, so the next one does not

- **`sf.write` defaults a .wav to PCM_16.** See §1 above. Anything downstream
  that reads with scipy and casts without scaling is off by ~90 dB.
- **The step-sequencer grid ignores `pianoRollPPB`.** Shot at ppb 20, 30 and 42
  the PNG is byte-identical — one md5 across three files. Its window is a fixed
  ~3.05 bars, so a 4-bar clip photographs with bar 4 off screen. Shoot the bar
  the chapter is about as its own clip.
- **A zoom crop's aspect ratio decides how big the picture ends up**, because
  the assembler letterboxes. A wide crop of a small region is worse than no
  crop at all.
- **`grep -c "A side"` returning 1 after a "successful" edit** is the whole
  no-op story. Assert the match count before writing.
- **A uniform result across many units is a broken probe**, twice in one build:
  −120.00 dB on four velocities × two drums, and a "median latency" that was
  identical because it was always the window edge.

## Staging, re-read field for field

| | before | after |
|---|---|---|
| tempo | 100 | **136** |
| tracks | Pad, Bass, Drums, Lead | **Kick, Snare, Cymbals** |
| markers | 0 | 0 |
| master volume | 1 | 1 |
| transport | stopped at beat 0 | stopped at beat 0 |
| panels | — | editor un-maximized 0.43, roll ppb 55 / row 14, steps→notes, mixer hidden |

⚠ **Staging (port 17695) now holds this film's project, not the one it held at
session start.** That prior project was `chasing-14`'s own build leftover, not
user work, and it is fully reproducible with
`scripts/video/lessons/chasing-14/shoot.mjs`. It was not restored because
re-running that build would re-render its audio, which is not this task's call
to make. Mine is saved and named rather than left ambiguous:
`media/Amen lesson (staging scratch).dawproj`.

**Port 17600 — the user's live app — was never contacted.** `build.mjs` refuses
it outright and no script here names a port.

## What is gitignored, and checked both ways

`out/` is 585 MB, `bursts/` 413 MB, `audio/` 155 MB, `manim/` 4.7 MB. All are
covered by the existing rules (`bursts/`, `shots/`, `*.wav`,
`/scripts/video/lessons/*/{manim,out,media}/`), verified with
`git check-ignore -v`. Positive control both ways: `spec.py` and `NOTES.md`
report **NOT IGNORED**, which is correct.
