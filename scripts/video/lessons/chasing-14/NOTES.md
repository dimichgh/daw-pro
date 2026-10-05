# Chasing −14 — rebuild notes

Every number this film says, where it came from, and the command that produced
it. Nothing here was copied out of the shipped film's description. The shipped
figures (−20.3 LUFS, 4.4 LU, +6.25 dB, +3.4 dBFS, 1594 clipped samples,
−46.5 dBFS of distortion) belong to a different mix and were treated as prior
art — the ARGUMENT to reproduce, not measurements to reuse.

## How to rebuild the whole thing

```bash
cd scripts/video/lessons/chasing-14
V=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python

# 1. the mix, every master, every still            (staging, port 17695)
DAW_CONTROL_PORT=17695 C14_AUDIO=$PWD/audio SESSION_SHOTS=$PWD/shots \
  SESSION_BURSTS=$PWD/bursts node shoot.mjs

# 2. the one screen recording (the playhead, at 30 fps)   — motion only
DAW_CONTROL_PORT=17695 node record.mjs

# 3. every measurement  ->  MEASUREMENTS.json + every A/B wav
$V measure.py

# 4. the seven matplotlib charts  ->  shots/chart-*.png
$V charts.py

# 5. the two manim scenes + the recording  ->  bursts/ + their audio
$V bursts.py                 # or `bursts.py mechanism` / `clipchart` for one
$V bursts.py --only-media    # re-crop the recording without re-rendering manim

# 6. the spec, then the film
$V spec.py
$V ../../shortsmith.py L6v2.json --out-dir $PWD/out      # NO --finalize
```

`tune.mjs` and `probe.mjs`/`probe2.mjs` are the throwaway probes that chose the
material and the compressor settings; they are kept because the choices they
made are otherwise unexplainable.

The speech server has to be up for step 6:
`plugins/narrated-film/.venv/bin/omlx serve --port 8000`, killed **by port**
afterwards. ⚠ With it down, `verify.py`'s content check reports **BROKEN** and
shortsmith does **not** block on BROKEN — a build done with the server stopped
silently downgrades from 8 ok to 7 ok + 1 BROKEN.

## The material, and why it is what it is

100 BPM, 16 bars, 38.4 s, 318 notes across four hand-written parts (pad, bass,
drum kit, lead), played by GeneralUser-GS sound-bank instruments. No generation
model, per the lesson-material rule.

**The one property the whole film depends on is the mix's PEAK-TO-LOUDNESS
RATIO**, because "the gain that reaches −14 pushes the peak past 0 dBFS" is a
property of the mix's crest factor and not of −14 at all. That was probed before
anything else was written (`probe.mjs`, `probe2.mjs`), and it took four passes:

| track volumes (pad / bass / drums / lead) | LUFS | peak dBTP | PLR | LRA |
|---|---|---|---|---|
| 0.62 / 0.85 / 0.80 / 0.55 | −7.99 | +5.21 | 13.2 | 11.77 |
| 0.16 / 0.22 / 0.34 / 0.14 | −19.86 | −6.10 | 13.8 | 10.95 |
| 0.11 / 0.55 / 1.30 / 0.085 | −18.58 | −0.99 | 17.6 | 2.97 |
| **0.088 / 0.44 / 1.04 / 0.068** | **−20.48** | **−2.19** | **18.3** | **3.63** |

The second row would have made the film impossible: at a PLR of 13.8, +5.86 dB
of gain lands the peak at −0.24 dBFS and **nothing clips**. Only the last row was
kept. Per-stem loudness at those volumes (`probe2.mjs`, via `render.bounce`
`excludeTrackIds`): Pad −27.85, Bass −28.40, Drums −20.98, Lead −24.05 LUFS.

## Everything measured

All of it is in `MEASUREMENTS.json`, written by `measure.py` from the renders
`shoot.mjs` made. `spec.py` injects every CARD figure from that file and
**asserts every SPOKEN figure against it** (39 `check()` calls), so a narration
that drifted from a measurement refuses to build.

### The controls, before any clipping figure is believed

| control | measured | what it proves |
|---|---|---|
| a file minus itself | **0 non-zero samples** (−240 dB) | the subtraction is exact |
| unclipped 24-bit minus its float twin | **−149.2 dBFS** | it returns the 24-bit floor and nothing else |
| the untouched mix, rendered to 24-bit | **0 clipped samples** | the method does not invent clipping |
| the app vs ffmpeg on five renders | **≤ 0.05 LU, ≤ 0.04 dBTP apart** | two independent instruments agree |

The last one is the one worth keeping: every loudness number in this film was
measured twice, by `render.measureLoudness` inside the app and by
`ffmpeg -hide_banner … ebur128=peak=true` outside it.

### The five masters

| master | LUFS | true peak | LRA | how |
|---|---|---|---|---|
| the mix, untouched | −20.50 | −2.20 dBTP | 3.70 | nothing on the master bus |
| gain only | −14.00 | **+4.30 dBTP** | 3.70 | +6.48 dB, and it clips |
| gain + true-peak limiter | −15.20 | −1.00 dBTP | 3.60 | the same +6.48 dB |
| compressor + limiter | −14.10 | −1.00 dBTP | 3.20 | +7.16 dB drive |
| the same chain, chasing −8 | −8.70 | −1.00 dBTP | 1.60 | +40.88 dB drive |

The chain: `gain → compressor (−18 dB, 2:1, 20 ms, 180 ms, 6 dB knee, +6 dB
makeup) → limiter (−1.0 dB ceiling, 120 ms, TRUE PEAK ON)`.

⚠ **`truePeak` defaults to 0 (sample peak).** With the default left alone the
"−1.0 dBTP" claim would have measured about −0.3 dBTP and been wrong.

### The clipping, at four targets

| target | gain | float peak | clipped samples | runs | longest | distortion | under the music |
|---|---|---|---|---|---|---|---|
| −14 | +6.48 | +4.25 dBFS | **944** | 506 | 23 (0.48 ms) | −54.62 dBFS | −38.46 dB |
| −11 | +9.48 | +7.25 | 25,916 | 6,298 | 171 (3.56 ms) | −36.14 | −22.78 |
| −8 | +12.48 | +10.25 | 90,256 | 9,079 | 301 (6.27 ms) | −24.43 | −13.36 |
| −5 | +15.48 | +13.25 | 158,241 | 13,476 | 376 (7.83 ms) | −16.85 | −7.82 |

A span of **37.77 dB** in the artefact, from one mix and one gain knob.

### The compressor, measured rather than described

`compoff.wav` and `compin.wav` are the same drive with the compressor bypassed
and engaged, the limiter out of the way in both. Dividing one by the other is
the compressor's own gain. **Median 3.38 dB of reduction, deepest 8.70 dB, past
3 dB for 59 % of the render**, with +6 dB of makeup put back after.

⚠ The raw quotient is the NET gain and its median is **+2.62 dB**, because of
that makeup — calling that "gain reduction" on screen would have been a sign
error. `chart-gr.png` plots `makeup − net`.

### The bill

3.70 LU became 3.20 LU for 6.40 dB of loudness: **0.50 LU, or 13.5 %.**
Driving the same chain to −8.70 LUFS costs **2.10 LU, or 56.8 %**, and takes
**+40.88 dB** of drive — which needed a SECOND gain insert, because one clamps
at +24.08 dB (see the trap list).

⭐ **That reframed the film, honestly and by measurement.** The shipped film's
headline was "6 dB of loudness cost nearly 3 LU of range". On this material −14
is CHEAP (half a LU) and everything past it is expensive. The rebuild says that
instead, because that is what the renders said.

## ⭐ The audibility fault, and what was done about it

**The fault, as briefed:** the shipped film isolated its clipping distortion at
−46.5 dBFS, 28 dB below the film's own level — a real, correctly measured
difference living where a laptop speaker cannot deliver it.

**On this material it is worse, not better: −54.62 dBFS, 38.46 dB under the
music, and at its very closest moment still 24.72 dB under.** That was measured
first and it is stated out loud in the film rather than hidden.

Three treatments, in the brief's order of preference, all measured before being
claimed:

1. **The source material was fixed — by adding rungs, not by faking the −14
   one.** The same clean/clipped pair is rendered at four targets. At −5 the
   artefact is −16.85 dBFS and comes within **0.49 dB** of the music; the film
   plays the isolated distortion from the −14 master and the −5 master **at one
   shared gain** (−14.1 dB, set from the louder so neither clips), so the
   34.09 dB between them is the real relationship rather than two files
   normalised to sound equally loud. Nothing about the −14 case is exaggerated:
   it stays −14, it just stops being the only rung.
2. **It is carried visually, five times.** `chart-waveform.png` (the whole mix
   before and after the gain, with everything above full scale filled red),
   `chart-flattop.png` (the longest clipped run, 23 samples, magnified — a curve
   replaced by a straight line), `chart-ladder.png` (artefact level and clipped
   count against target), `anim_clip.py` (the mechanism, animated at **the mix's
   own measured peak** so the red areas are the right size and not merely the
   right idea) and `anim_time.py` (the attention marker).
3. **The film says plainly what cannot be heard**, twice — in the narration of
   `08-honest` and as card 15 — with the measured figure, never as "listen
   closely" and never as the viewer's fault.

### The honesty beat the standard demands

Louder wins a blind A/B. Stage `14-louder` plays the mix against the −14 master
**unmatched**, one shared gain, a real **6.2 LU** difference, and says out loud
that the second one is not better, it is louder. Stage `15-matched` plays the
same pair with the master pulled down by exactly 6.2 dB so both sit at
−19.0 LUFS, and says what the matching left behind: the level not moving.

`normalize: false` on every stage whose level difference is the lesson (03, 05,
10, 11, 14, 15), set deliberately rather than waiting for the gate.

## The attention marker

`anim_time.py`. One curve per rung: the clipping's level **relative to the
music**, 80 ms RMS, floored at −60 dB (below which there is no clipping at all).
The shaded windows are **derived** — every stretch where the −5 master's
artefact comes within 40 dB of its own music, gaps under 150 ms merged, anything
under 200 ms dropped — which gives three windows. The 40 dB is stated on screen
as a rule of thumb about small speakers, not as a measurement, because that is
what it is.

The scene **prints its own sweep offsets** and `bursts.py` builds the audio bed
from those offsets, so `run_time` and the audio cannot drift apart.

## Choices made without asking (the user was asleep)

- **Length.** 2,700-odd words over 19 stages. The directive says there is no time
  budget and that explainability is the goal, so nothing was trimmed. Three
  chapters exist purely to explain and demonstrate nothing (01 what the three
  meters are, 02 where −14 comes from, 07 the controls).
- ⛔ **The app's live LOUDNESS readout was shot and then deliberately dropped.**
  The master strip carries live M / S / I / LRA / TP — exactly the meters this
  lesson is about — but they are POST-FADER. Every burst in this repo drops the
  master to 0.03 so a build does not shout out of the machine's speakers at
  night, and at 0.03 the readout measured **I −40.2 LUFS** on a master the
  renders put at −14.05. The honest fix is a master at unity, which means
  playing the mix aloud on a sleeping user's laptop — measured: system output
  volume **38**, not muted. A wrong number on screen is worse than no picture,
  so the film reads its loudness off the renders and the charts, and the app
  appears through the mixer stills and the three insert cards. `shoot.mjs`
  carries the same explanation at the point where the shots used to be taken.
- **One screen recording, for the playhead only.** `debug.captureUI` managed
  **3.30 fps** on that very shot; `record.mjs` records the same thing at 30.
  `--app DAWApp`, master at **0** (nothing in this recording is an
  output-fed meter, so there is no reason to make noise). `media/_first_arrange.png`
  and `media/_last_arrange.png` were BOTH extracted and BOTH looked at: each
  shows the DAWApp window alone, four tracks named Pad / Bass / Drums / Lead,
  and the transport counting from 0:00.782 to 0:08.836 — real motion, right
  window. The window was NOT resized.
- **The gain card is photographed twice, on purpose.** `fx-gain-naive.png` is
  shot while the gain is the ONLY thing on the master (it reads 6.5 dB, the app's
  rounding of +6.48) and `fx-gain.png` with the finished chain (7.2 dB). The
  narration says "the knob rounds it to six point five, but the value underneath
  is six point four eight" so the panel and the voice agree rather than
  contradicting each other by 0.02 dB.
- **The compressor settings were chosen by measurement, not taste** (`tune.mjs`):
  five candidate chains were solved to −14 and the one kept (−18 dB, 2:1,
  +6 dB makeup) is the one whose DRIVE is a plausible mastering number
  (+7.16 dB). A −18 dB threshold with no makeup needed **+19.07 dB** of drive to
  reach the same place, which reads as nonsense on screen.

## Traps hit during this build, so the next one does not

- ⛔ **`bitDepth: 32` IS 32-BIT INTEGER and clamps.** The float render is the one
  that OMITS `bitDepth` entirely. Getting that backwards would have made the
  clipping demo silently impossible: both files identical, residual −inf.
- ⛔⛔ **`screenrec` with no arguments does not print help — it records the
  *Dock* for ten seconds and writes `screenrec.mp4` beside itself.** That
  happened here (`./screenrec --help`) and the file was deleted immediately.
  Never invoke it without `--app`.
- ⚠ **`fx.setParam` clamps a gain insert at +24.08 dB SILENTLY** (the clamp is
  reported in `warnings`, which nothing was reading). The first attempt at the
  −8 master ran seven identical solver steps against a clamped parameter and
  reported a confident, wrong −12.40 LUFS. `solveDrive` now splits the drive
  across two inserts and prints any clamp warning.
- ⚠ **A solver that reports the value it MEASURED while leaving the value it
  LAST TRIED in the chain.** The first version rendered `mastered.wav` at
  +18.80 dB while `facts.json` said +18.97. `solveDrive` re-sets the winning
  gain before returning.
- ⚠ **Two mixer stills shot after the same edit are the same picture.**
  `mixer.png` and `mixer-mastered.png` came back byte-identical; `md5 -q
  shots/*.png | sort | uniq -d` is what caught it. The dry stills are now shot
  before a single master insert exists.
- ⚠ **A peak-preserving decimation is not optional on the waveform chart.** 944
  clipped samples out of 1.9 million disappear entirely under a plain stride,
  and the chart would have shown a waveform politely under the ceiling.
- ⚠ **Bar charts of a negative quantity.** The first `chart-masters.png` hung the
  LUFS bars down from zero, so the QUIETEST master had the LONGEST bar. They grow
  up from a −24 floor now.
- ⚠ **manim captions written across the plot.** Both scenes had captions drawn
  straight through the curve on their first render, and `anim_clip.py`'s residual
  trace shot off the top of the frame at a fixed 6× gain. Found by looking at
  frames, not by any gate.
- ⚠ **The digit/word trap, twice.** `00-open` lost a full eight-take round to
  Whisper writing `minus 14` for "minus fourteen" (the factCheck listed `-14`
  and `−14` but not `minus 14`), and another to it writing **`DW Pro`** for
  "DAW Pro" — `brandCheck` is a single exact substring with no variants, so the
  opening and closing stages now say the product name TWICE each, which gives
  every take two independent chances.
- ⚠ **shortsmith's pre-flight is worth reading.** It refused to narrate three
  stages whose `factCheck` strings were not in their own scripts
  ("one hundred and fifty eight thousand" vs "a hundred and fifty eight
  thousand"). That is a spec typo caught in one second instead of after eight
  takes of synthesis.
- ⚠ **`build.mjs` reads `DAW_CONTROL_PORT` and DEFAULTS to 17695**, and it
  refuses 17600 outright. A mistyped variable name therefore still reaches
  staging — which is safe, but means a wrong env var name fails silently.
- ⚠ **The two superimposed captions at 3:45 in `05-mechanism` are not a
  defect.** manim crossfades cap2 out and cap3 in over 0.5 s at the top of
  the gain rise; a frame sampled inside that window catches both.
- **Two pictures repeat, deliberately.** Card 8 (the four-target list) opens
  both `09-ladder` and `11-marker`, and `chart-ladder.png` is held in both
  `08-honest` and `09-ladder`. Both chapters genuinely need those pictures
  under their words, and they are 90 s apart; I judged the repetition
  cheaper than pointing a chapter at a picture it is not describing.
- ⚠ **The corner meter eats bottom-right text.** `spec["meter"] = "br"` burns a
  live level meter into the corner after the segments are built. Every manim
  caption in this film is LEFT-aligned and every chart footnote is wrapped to
  stay clear of about x = 0.72.

## The film as built

`out/L6v2.mp4` — 1920x1080, h264 yuv420p 30 fps, AAC 48 kHz stereo.
**842.40 s (14:02), 44.8 MB (46,981,972 bytes), md5 `edf3e7b1017fae986c68e96e8313dc08`.**
Not finalised, not published; the shipped film's filename is untouched.

Loudness of the deliverable, measured with a second instrument
(`ffmpeg -hide_banner -i out/L6v2.mp4 -af ebur128=peak=true -f null -`):
**I −17.2 LUFS, LRA 3.4 LU, true peak −1.3 dBFS** — the same figures
`verify.py` reports from its own pass.

### verify.py, final build (`/tmp/c14-build5.log`)

    [  ok  ] streams: v=h264,1920,1080,yuv420p,30/1  a=aac,48000,2  842.4s
    [  ok  ] frame size: 1920x1080 (landscape), as the manifest asks
    [  ok  ] a/v drift: 12.3 ms (under one frame)
    [  ok  ] distinct frames: 5 of 5 consecutive pairs differ (max 31.04, min 13.08,
             noise floor 2.0); control: frame vs itself = 0.00
    [  ok  ] audio present: audio at all 4 sample points
    [  ok  ] loudness: -17.2 LUFS / -1.3 dBTP  (no target stated)
    [  ok  ] A/B separation: 10-isolate src -26.20 -> film -25.10 LU;
             14-louder src -6.20 -> film -6.20 LU; 15-matched src +0.00 -> film +0.00 LU
    [  ok  ] content: best-matching stage 0.32 vs worst-matching control 0.03
             (separation 11.9x over 6 blind windows) -- the film says its script
    exit 0

⚠ The `842.4s is OVER the 60 s Shorts limit` line is shortsmith's Shorts advice,
not a failed check. This is a long-form lesson, like mono-bass.

⚠ `10-isolate` is the one A/B whose in-film separation drifts from source
(−26.20 LU asked, −25.10 LU measured). MEASURED rather than guessed, with
`ffmpeg -hide_banner -ss <t> -t 8 -i out/L6v2.mp4 -af ebur128 -f null -` against
the same command on the source wav:

| half | source wav | in film | drift |
|---|---|---|---|
| BEFORE (`resid14`) | −52.1 LUFS | −51.8 LUFS | +0.3 LU |
| AFTER  (`resid5`)  | −25.9 LUFS | −26.7 LUFS | −0.8 LU |

So the 1.1 LU is not one effect. Only 0.3 LU of it is the quiet half reading
high near ebur128's absolute gate; the larger 0.8 LU is the LOUD half reading
low in the film, which I did not chase further — most likely the AAC round-trip
plus the window boundary, but I did not measure that and am not claiming it.
1.1 LU on a 26 LU difference; the check's tolerance passes it. The other two
A/Bs land exactly.

### Brand spot-transcription of the DELIVERABLE, with a negative control

The content check inside `verify.py` is a per-stage similarity score. This is a
separate check on the finished mp4: cut three windows out of the film, send them
to the same Whisper endpoint, and ask for the exact substring.

    ffmpeg -ss 5   -t 28 -i out/L6v2.mp4 -vn -ac 1 -ar 16000 open.wav
    ffmpeg -ss 825 -t 16 -i out/L6v2.mp4 -vn -ac 1 -ar 16000 close.wav
    ffmpeg -ss 305 -t 28 -i out/L6v2.mp4 -vn -ac 1 -ar 16000 control.wav

| window | "DAW Pro" present |
|---|---|
| 0:05–0:33 (`00-open`) | **yes** — "…built and measured inside DAW Pro…" |
| 13:45–14:01 (`18-close`) | **yes** — "…built and rendered in DAW Pro, and measured off those DAW Pro renders." |
| 5:05–5:33 (`08-honest`) — negative control | **no** |

The control window transcribed correctly ("minus 54.6 decibels below full
scale… 38.5 decibels underneath") and did not contain the brand, so the check
can return false.

### Narration takes

Every one of the 20 stages passed the transcribe-and-compare gate. Across the
whole build only two stages ever needed more than one round of authoring, and
both were caught by the gate rather than by ear:

- `00-open` lost two full eight-take rounds. Whisper wrote `minus 14` for
  "minus fourteen" (factCheck listed only `-14`/`−14`), then wrote `DW Pro`
  and `DAO Pro` for "DAW Pro". `brandCheck` is a single exact substring with no
  variants, so the fix was to say the product name TWICE in both branded
  stages — each take then gets two independent chances.
- Similarities at each stage's LAST NARRATION (builds 3 and 4 — build 5
  re-narrated nothing, every stage hit the vo cache): `09-ladder` 0.99,
  `13-compressor` 1.00, `13b-result` 0.99.

### Chapters (measured from the assembled segments, not from the spec)

Computed by summing `ffprobe` durations over `out/segments/_all.txt` in the
order the concat demuxer reads them; the total, 842.35 s, agrees with the
container's 842.40 s.

    0:00.00      0.00 +  4.00  intro
    0:04.00      4.00 + 34.72  00-open-talk
    0:38.72     38.72 + 37.44  01-meters-talk
    1:16.16     76.16 + 28.16  02-why-talk
    1:44.32    104.32 + 30.72  03-mix-talk
    2:15.04    135.04 +  8.00  03-mix-play
    2:23.04    143.04 + 37.60  04-arithmetic-talk
    3:00.64    180.64 + 33.12  05-mechanism-talk
    3:33.76    213.76 + 21.80  05-mechanism-play
    3:55.56    235.56 + 31.20  06-count-talk
    4:26.76    266.76 + 36.64  07-controls-talk
    5:03.40    303.40 + 29.76  08-honest-talk
    5:33.16    333.16 + 42.88  09-ladder-talk
    6:16.04    376.04 + 22.24  10-isolate-talk
    6:38.28    398.28 +  8.00  10-isolate-ab0-before
    6:46.28    406.28 +  8.00  10-isolate-ab0-after
    6:54.28    414.28 +  8.00  10-isolate-ab1-before
    7:02.28    422.28 +  8.00  10-isolate-ab1-after
    7:10.28    430.28 + 41.76  11-marker-talk
    7:52.04    472.04 + 23.79  11-marker-play
    8:15.83    495.83 + 45.92  12-limiter-talk
    9:01.75    541.75 + 33.28  13-compressor-talk
    9:35.03    575.03 + 31.68  13b-result-talk
    10:06.71    606.71 + 28.32  14-louder-talk
    10:35.03    635.03 +  8.00  14-louder-ab0-before
    10:43.03    643.03 +  8.00  14-louder-ab0-after
    10:51.03    651.03 +  8.00  14-louder-ab1-before
    10:59.03    659.03 +  8.00  14-louder-ab1-after
    11:07.03    667.03 + 29.44  15-matched-talk
    11:36.47    696.47 +  8.00  15-matched-ab0-before
    11:44.47    704.47 +  8.00  15-matched-ab0-after
    11:52.47    712.47 +  8.00  15-matched-ab1-before
    12:00.47    720.47 +  8.00  15-matched-ab1-after
    12:08.47    728.47 + 37.28  16-bill-talk
    12:45.75    765.75 + 31.68  17-past-talk
    13:17.43    797.43 + 41.92  18-close-talk
    13:59.35    839.35 +  3.00  outro
    TOTAL 842.3499999999999

### The two review passes

Build 2 was fully green and still wrong in places a gate cannot see. Both passes
were done by extracting frames at the CUT MOMENTS (not chapter starts) into
contact sheets and looking at them.

Pass 1 (six stages re-cut, one split): `05-mechanism` talked over a filler card
while describing a waveform; `09-ladder` and `11-marker` held their summary CARD
while the voice described the CHART; `12-limiter` held the inserts list while
the voice read the limiter's ceiling and true-peak values; `08-honest` and
`14-louder` gave their key explainer cards 4.4–6.0 s; `13-compressor`'s 46 s of
narration could not follow three pictures at any cut length and became
`13-compressor` + `13b-result`.

Pass 2 (three defects, all in things verify.py measures as healthy):

1. **`mech.wav` played two takes at once for 1.5 s.** `bursts.lay()` is
   additive. With `RISE = 6.0` the clipped drop-in landed at 9.6 s while the
   8-second clean excerpt ran to 11.1 s. Measured, not assumed: the overlap
   window peaked at 0.766 (it did NOT clip — the prediction that it would was
   wrong), but a film about clipping was playing the same passage summed with
   itself. `RISE` is now 8.0, the rise ends exactly where the clean excerpt
   ends, and the gap between the two excerpts measures digital silence
   (`np.abs(x[11.1s:11.6s]).max() == 0.0`, with both neighbouring windows
   non-zero as the positive control).
2. **`03-mix` played bars 10–13 over footage of bars 1–4.** `ab-dry.wav` is cut
   at 21.6 s = beat 36; `record.mjs` recorded from beat 0, so the soundtrack had
   a full kit and a lead while the picture showed the drums not yet started.
   `record.mjs` now seeks to beat 34.8 before playing; the first frame of the
   new take reads `POSITION 9.4 / TIME 0:21.587` — 13 ms from the excerpt's own
   start.
3. **Two captions were unreadable.** `anim_clip`'s two-line residual caption ran
   off the BOTTOM of the frame (the second line was half a row of pixels in the
   exported still); `anim_time`'s footnote shared a pixel row with the "seconds"
   axis label, so the frame read "…about where a small seconds speaker stops
   delivering it". Both fixed and both re-checked in the assembled film, not
   just in the scene render.

And one wording defect the swap in pass 1 created: `09-ladder` said the
distortion runs "from minus fifty four point six at the top of the chart to
minus sixteen point nine at the bottom", which described the CARD. On
`chart-ladder.png` −14 is bottom-LEFT and −5 is top-right, so once the chart was
held under those words the spatial language was inverted. Reworded to name the
targets instead of screen positions.

