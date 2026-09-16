# Mono Your Bass — rebuild notes

Every number this film says, where it came from, and the command that produced
it. Nothing here was copied out of the shipped film's description; the shipped
figures (a 10.16 dB fold at 60–110 Hz) belong to a different bass line and were
treated as prior art, not as measurements.

## How to rebuild the whole thing

```bash
cd scripts/video/lessons/mono-bass
V=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python

# 1. material + renders + stills + the arrange burst   (staging, port 17695)
DAW_CONTROL_PORT=17695 SESSION_SHOTS=$PWD/shots SESSION_BURSTS=$PWD/bursts \
  MB_AUDIO=$PWD/audio node shoot.mjs

# 2. the two screen recordings of the correlation meter   (motion only)
DAW_CONTROL_PORT=17695 node record.mjs

# 3. every measurement  ->  MEASUREMENTS.json + the A/B and chart wavs
$V measure.py

# 4. the five matplotlib charts  ->  shots/chart-*.png
$V charts.py

# 5. the two manim scenes + the meter crops  ->  bursts/ + their audio
$V bursts.py            # --meters re-crops the recordings without re-rendering

# 6. the spec, then the film
$V spec.py
$V ../../shortsmith.py L8v2.json --out-dir $PWD/out      # NO --finalize
```

The speech server has to be up for step 6:
`plugins/narrated-film/.venv/bin/omlx serve --port 8000`, killed **by port**
afterwards.

## The material

100 BPM, so one beat is exactly 600 ms and a 6 ms nudge is exactly 0.01 beat.
47 notes, 8 bars, hand-written, played by two identical `polySynth` saw patches
(cutoff 1400 Hz) on two tracks panned hard left and hard right. The right-hand
copy's **notes** are shifted, not its clip — a clip position can be snapped by
an overlap/quantise policy and a 0.01-beat nudge would vanish silently.

**A saw, not a sine, deliberately.** The shipped film's whole demonstration was
a 60–110 Hz level difference, which is the audibility fault this rebuild exists
to fix. Harmonics are what a small speaker reproduces, so the material has to
have some for the mid-band consequence to be measurable at all.

The nine pitches were chosen from the prediction, not for the tune: at τ = 6 ms
the comb's first null is 83.3 Hz, and E2 (82.41 Hz) sits on it while E1
(41.20 Hz), the same note an octave down, sits nearly clear of it.

## Everything measured

All of it is in `MEASUREMENTS.json`, written by `measure.py` from the renders
`shoot.mjs` made. `spec.py` injects the card figures from that file and
**asserts every spoken figure against it** (`check()`), so a narration that
drifted from a measurement refuses to build.

### The experiment did what it says (controls)

| what | measured | how |
|---|---|---|
| offset, 0 / 6 / 15 ms | **0.0000 / 6.0000 / 15.0000 ms** | L-vs-R cross-correlation of each render (`lag_ms`) |
| left channel, 60–110 Hz | **−31.888 dB in all three** | band RMS of channel 0 only |

The left-channel figure is identical to the third decimal across the three
renders, so nothing below is the instrument, the mix or the encoder — it is
summing.

### The headline

Mono fold = (L+R)/2, band RMS 60–110 Hz:

| offset | 60–110 Hz | change |
|---|---|---|
| none | −31.888 dB | (the control) |
| 6 ms | −46.867 dB | **−14.979 dB** |
| 15 ms | −35.331 dB | −3.443 dB |

### Predicted, then measured — nine notes

`20·log10|cos(π f τ)|` at τ = 6 ms, against the fundamental's level in the
6 ms fold divided by its level in the 0 ms fold (200 ms window inside the note):

| note | Hz | predicted | measured |
|---|---|---|---|
| E1 | 41.20 | −2.94 | **−2.88** |
| A1 | 55.00 | −5.86 | −5.80 |
| B1 | 61.74 | −8.05 | −7.97 |
| D2 | 73.42 | −14.62 | −14.50 |
| E2 | 82.41 | −35.16 | **−34.98** |
| F#2 | 92.50 | −15.29 | −15.27 |
| G2 | 98.00 | −11.28 | −11.19 |
| A2 | 110.00 | −6.34 | −6.28 |
| C3 | 130.81 | −2.16 | −2.09 |

Agreement is 0.06–0.18 dB across all nine. The spread between best and worst
case is 32.9 dB, from one delay.

### One note, harmonic by harmonic (E2)

| harmonic | Hz | predicted | measured |
|---|---|---|---|
| 1 | 82 | −35.16 | −33.13 |
| 2 | 165 | −0.01 | **+0.03** |
| 3 | 247 | −25.62 | −25.58 |
| 4 | 330 | −0.02 | +0.03 |
| 5 | 412 | −21.19 | −21.20 |
| 6 | 494 | −0.05 | +0.08 |
| 7 | 577 | −18.28 | −18.55 |
| 8 | 659 | −0.09 | −0.03 |

Odd harmonics land in the notches, even ones land between them and do not move.

## ⭐ The audibility fault, and what was done about it

**The fault, as briefed:** the shipped film's sub-100 Hz content sits only
6.7 dB below its own full-mix level, and the entire demonstration is a
60–110 Hz level difference — so on laptop speakers the viewer largely cannot
hear the thing being demonstrated.

**What was NOT done:** the bass was not boosted, and no band was EQ'd.

Three honest treatments, all measured first:

1. **The fold is shown as a measured chart, twice.** `chart-comb.png` is the
   6 ms mono fold's Welch PSD divided by the 0 ms one across 25–1200 Hz, with
   the closed-form prediction over it — they lie on top of each other. And the
   attention-marker chart (`anim_time.py`) is short-time 40–130 Hz level over
   7.2 s of both renders, with a playhead sweeping it at real time.
2. **A mid-band consequence was looked for and MEASURED before being claimed.**
   Above 200 Hz — roughly what a laptop radiates — the same two renders differ
   by **−3.196 dB** (`hp200_full_loss_db`). That is real and above the ~1 dB
   loudness JND, but it is **not** fifteen, and the film says exactly that
   rather than implying more. The stronger mid-band statement is the E2
   harmonic table: the note does not merely get quieter, it loses every other
   partial, which is a change of character rather than of level.
3. **The film says plainly that this one is better on headphones**, as a card
   (card 10) and in the opening narration, never as a gate and never phrased as
   the viewer's fault.

The A/B halves are also honest about level: `normalize: false` on every stage
whose level difference is the lesson, and **one shared static gain** (+10.60 dB,
set from the loudest of the three excerpts so nothing clips) applied to all of
them. Measured source loudness of the A/B halves: ab0 **−15.2 LUFS**, ab6
**−19.8 LUFS**, ab15 **−19.0 LUFS** (`ffmpeg -hide_banner -i x.wav -af
ebur128=peak=true -f null -`). `verify.py`'s A/B separation check compares the
film's delta against those source deltas.

## The attention marker

`anim_time.py`. The shaded listen-windows are **derived**: every window where
the 6 ms fold is more than 6 dB quieter than the 0 ms fold in 40–130 Hz, gaps
under 120 ms merged, anything under 150 ms dropped. `measure.py` computes them;
the scene reads them out of `MEASUREMENTS.json`. Maximum difference inside the
window: 31.42 dB.

The scene **prints its own sweep offsets** and `bursts.py` builds the audio bed
from those offsets, so `run_time` and the audio cannot drift apart.

## Choices made without asking (the user was asleep)

- **Length.** 2362 words of narration over 16 stages. The directive says there
  is no time budget and that explainability is the goal, so nothing was trimmed
  for length. Two chapters exist purely to explain (01 what mono is, 02 what
  cancellation is) and neither demonstrates anything.
- **A screen recording, not stills, for the correlation meter.** It is a needle
  that moves; `debug.captureUI` runs at ~3 fps. Recorded `--app DAWApp` only, at
  `--scale 2.0`. `media/_first_mixer0.png` and `media/_first_mixer6.png` were
  BOTH extracted and BOTH looked at: each shows the DAWApp mixer alone, two
  Poly Synth strips at PAN L100 / R100, and the MONO SAFETY readout — `+1.00 IN
  PHASE` on the 0 ms take, `−0.34` in red on the 6 ms one. (An earlier draft of
  these notes claimed both had been inspected when only the 6 ms one had; the
  claim is now true.) The
  window was NOT resized (a resize would change the still dimensions mid-film).
- **Master volume 0.03 while recording the meter**, not 0. At 0 the meter reads
  a static idle `+1.00 IN PHASE` with an empty goniometer — the first take of
  those shots reported "IN PHASE" for all three offsets and two of six files
  were byte-identical. 0.03 is about −30 dB.
- **The `screenrec` binary was not rebuilt.** Both recordings succeeded and were
  inspected; the two fixes announced mid-build address failure modes that did
  not occur here.

## Traps hit during this build, so the next one does not

- **The correlation meter is fed from the OUTPUT.** See above — a silent master
  makes it read a confident, wrong, static value.
- **`Text(font=FONT, "x")` is a SyntaxError** (keyword before positional). A
  search-and-replace that adds `font=` to every `Text(` breaks every manim
  scene; both scenes use a `T()` wrapper instead.
- **`next_to()` measures the CURRENT bounding box**, so rotating a y-axis label
  after placing it swings it off the frame. The first render of `anim_time.py`
  had no y-axis label at all, and the second had it drawn through the tick
  numbers (`next_to(ax, …)` cannot see the ticks, which are separate mobjects).
- **A manim scene's printed length must be checked against the render.**
  `anim_phase.py` printed 16.00 s for a scene that renders 18.00 s; `bursts.py`
  now compares them and says so.
- **Bar charts of a negative quantity.** The first `chart-offsets.png` drew
  absolute band levels hanging down from 0 dB, so the WORST case was the
  LONGEST bar, which reads as "biggest". Both bar charts plot the loss instead.

## The film as built

`out/L8v2.mp4` — **672.9 s (11:13)**, 1920×1080 h264 / 48 kHz AAC stereo,
34.9 MB. `−16.7 LUFS integrated, −1.0 dBTP` (measured by `verify.py`).
**NOT finalized, NOT published**; the shipped
`~/Movies/DAW Pro Lesson 8 - Mono Your Bass.mp4` is untouched. The spec's
`filename` is deliberately different (`… (rebuild)`), so even a stray
`--finalize` could not overwrite it.

Sixteen chapters, 565.6 s of explanation against 100.3 s of demonstration —
`out/segments/*-mux.mp4`, measured with ffprobe. Chapter timings are the segment
lengths in that directory; the A/B halves' absolute positions are in
`out/L8v2.mp4.timeline.json`.

`verify.py` — **all 8 checks ok**, including `A/B separation`:

```
06-listen  src +4.60 LU -> film +4.70 LU
11-counter src -0.80 LU -> film -0.90 LU
```

(the second pair's sources differ by under 1 LU, so the gate reports it without
judging it — and the film says out loud that this pair is a bass difference).
Content gate: best-matching stage 0.29 against a worst-matching control 0.03,
a 9.4× separation over 6 blind windows.

Narration: every stage passed the transcribe-back gate first time except two,
both of which were **gate bugs, not speech bugs** (see below); observed
similarity scores ran 0.95–1.00. ⚠️ The `"cached"` entries in
`out/build-report.json` carry a placeholder `1.0`, not a measurement — the real
scores are in the build log of the run that recorded each take.

### Two takes rejected for saying the number correctly

Both are the documented digit/word trap and both cost a full 8-take round:

- `02-cancellation`: a verbatim take said "about twelve milliseconds"; Whisper
  wrote `12 milliseconds`; the gate only listed the word form.
- `06-listen`: the take said "plus one point zero zero"; Whisper wrote
  `plus 1.00`.

Every numeric `factCheck` now carries its digit spelling.

### One take rejected for a real content fault

`11-counter` take 1 came back as *"Since milliseconds is bad"* for *"If six
milliseconds is bad"* — at a similarity of 0.96, comfortably over the 0.80
floor. An aggregate score cannot gate a three-word substring, so that stage now
carries an explicit `["six milliseconds", "6 milliseconds"]` check. Take 4
passed at 0.995 and its transcript reads "If 6 milliseconds is bad".

### The corner meter eats bottom-centre text

`spec["meter"] = "br"` burns a live level meter into the bottom-right corner
AFTER the segments are built. Centred bottom captions run under it: the first
cut had *"every peak meets a trough"* reading as *"every peak meets a tro"*, and
`chart-audibility.png`'s footnote was cut mid-sentence. Fixed by pinning
`anim_phase.py`'s captions to the LEFT edge and shortening that one footnote.
**Keep anything at the bottom clear of about x = 0.72.** Found by looking at
frames, not by any gate.

## Re-measuring the fault, honestly

The brief's diagnostic was the film's own sub-100 Hz share. Measured with
`ffmpeg -hide_banner -i FILM -af [lowpass=f=100,]astats=metadata=1 -f null -`:

| film | full-band RMS | below 100 Hz | gap |
|---|---|---|---|
| shipped | −20.41 dB | −27.12 dB | 6.71 dB |
| this rebuild | −19.20 dB | −26.80 dB | **7.60 dB** |

**That number did not improve, and it was never going to.** The film is still
about a bass line, so it still has bass in it; the metric measures the subject,
not the fault. What changed is what the lesson RESTS on:

- the mechanism is now an animation of two waves cancelling, not an assertion;
- the fold is a measured spectrum with its prediction drawn over it;
- the note-by-note and harmonic-by-harmonic results are charts;
- the app's own correlation meter is on screen, live, going red;
- and the film states the laptop-band figure (−3.20 dB) out loud instead of
  leaving the viewer to discover that they cannot hear −14.98.

A viewer on laptop speakers can now follow every step of the argument with the
sound turned down. That is the thing the shipped film could not do.

### Brand substring, checked on the DELIVERABLE

`PROGRAM.md`'s fifth "done" condition. Two 16–22 s windows cut out of the
finished mp4 and transcribed with the same Whisper model:

- 4–26 s → *"…It is built and measured inside **DAW Pro**, and nothing in it is
  an opinion…"* — present.
- 650–666 s → *"…was built and rendered in **DAW Pro** and measured off those
  renders…"* — present.

⚠️ The first attempt sampled 20–45 s and 660–672 s and found nothing, which is a
reminder that a negative here means *"you sampled the wrong 20 seconds"* far
more often than it means the brand is missing. Both windows were re-cut around
the sentences that actually carry it.


## Second review pass (2026-09-05) — three things a green verify.py could not see

The film was rebuilt once more after `verify.py` was already 8/8. None of these
were gate failures; all three were found by reading the spec against the frames.

1. **08-chart talked over the wrong picture.** Its TALK shots were
   `[chart-comb.png, card 4]` while the narration says "this chart is the level
   of the bass … across seven seconds … the pale line … the red line … the
   shaded bars" — a description of the TIME chart, which only appeared in the
   PLAY beat that followed. Fixed by having `bursts.py` copy the foldchart
   burst's LAST frame to `shots/foldchart-final.png` after every render, and
   pointing 08 at that. ⚠ Never reference `bursts/foldchart/f####.png` from the
   spec: `explode()` wipes that directory on every re-render.
   Verified in pixels at t=340 s (the chart) and t=345 s (card 4 — the stage
   alternates its stills every `cut=5.0` s, which is why a single sample at
   345 s looked like the fix had not taken).
2. **Card 9 was written and never shown.** It carries the honest six-vs-fifteen
   figures (6.2 dB apart below 130 Hz, 0.31 dB above 200 Hz) that stage 11's
   narration reads out, but no stage listed it. `11-counter`'s shots are now
   `[8, 9, chart-offsets.png]`. Verified in pixels at t=467.5 s.
3. **`shoot.mjs` pointed at a script that never existed.** Its meter-burst loop
   said the frames would be "cropped and enlarged later by metercrop.py". There
   is no metercrop.py; the film's meter footage comes from `record.mjs` +
   `bursts.py`. The loop shot ~3 fps bursts nothing consumed. Removed, with a
   comment saying what replaced it — for the pilot whose point is that nobody
   has to reverse-engineer this film, a comment naming a phantom file is the
   first thing the next person trips on.

Rebuild cost: all sixteen narration takes came from cache (`vo: … unchanged,
kept`), so no line was re-recorded and no gate was re-rolled. `verify.py` is
8/8 again, with the speech server up for the content check — ⚠ **with the omlx
server down the content check reports BROKEN rather than failing, and
shortsmith does not block on BROKEN**, so a rebuild done with it stopped would
have silently downgraded 8 ok to 7 ok + 1 BROKEN.

## Two E2 numbers, both correct

The film shows E2's fundamental at −34.98 dB on the per-note chart and
−33.13 dB on the harmonics chart. Same note, different analysis windows: the
per-note chart takes a 200 ms window on the FIRST E2, the harmonic breakdown a
420 ms window on the long, sustained E2. Neither is wrong and neither was
rounded toward the other.

## What is gitignored, and what was not

`out/` is 546 MB and `bursts/` 499 MB. Only `*.mp4` and `*.wav` were caught by
the existing rules — **the PNG frame bursts and `out/frames` were NOT ignored**,
so a `git add` of this directory would have staged about a gigabyte of frames.
Added to `.gitignore` (working tree only, not committed):
`bursts/`, `/scripts/video/lessons/*/manim/`, `/scripts/video/lessons/*/out/`,
`/scripts/video/lessons/*/media/`. Checked with `git check-ignore -v` and
positive-controlled against `spec.py` and `NOTES.md`, which are correctly NOT
ignored.

## Known duplication, left alone

`record.mjs` re-declares the RIFF and the synth patch by hand rather than
reading `audio/riff.json`, which `shoot.mjs` already writes. The two agree
today (the recording was made in the same session as the render), but a future
edit to the riff would drift them apart silently. Reading riff.json is the
right fix and is a five-line change; it was not made because `shoot.mjs` had
already run and re-running it would re-shoot every still for no gain.
