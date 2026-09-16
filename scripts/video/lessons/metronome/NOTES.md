# Lesson 7 rebuild — "Beethoven's metronome marks are too fast. Nobody knows why."

Rebuild of the shipped `DAW Pro Lesson 7 - Beethovens Metronome.mp4` (182.2 s) to
the house standard set by the amen / mono-bass / chasing-14 / beethoven-128 /
comma / bach-house rebuilds.

**NOT finalized.** The deliverable is written under a deliberately different
name so it cannot overwrite the shipped film. Replacing the published lesson is
the user's call, not this build's.

## The deliverable

```
/Users/dsemenov/Views/daw-pro/scripts/video/lessons/metronome/out/L7v2.mp4
```

| | measured |
|---|---|
| duration | **908.23 s = 15:08** (`ffprobe`) |
| size | **49,561,037 bytes** (47.3 MB, `wc -c`) |
| video | h264, **1920×1080**, yuv420p, 30/1 |
| audio | aac, 48 000 Hz, stereo |
| integrated loudness | **−17.4 LUFS** (`ebur128`, re-measured on the file after the build) |
| true peak | **−1.2 dBTP** |
| loudness range | 3.8 LU (low −20.0, high −16.3) |

`verify.py` **8/8 ok**, every check with its control:

```
[ ok ] streams: v=h264,1920,1080,yuv420p,30/1  a=aac,48000,2  908.2s
[ ok ] frame size: 1920x1080 (landscape), as the manifest asks
[ ok ] a/v drift: 25.0 ms (under one frame)
[ ok ] distinct frames: 5 of 5 consecutive pairs differ (max 23.18, min 3.00,
       noise floor 2.0); control: frame vs itself = 0.00
[ ok ] audio present: audio at all 4 sample points
[ ok ] loudness: -17.4 LUFS / -1.2 dBTP  (no target stated)
[ ok ] A/B separation: 11-ab-tempo src +0.10 -> film +0.10 LU (content +2.9 dB);
       14-eroica src +0.10 -> film +0.30 LU (content +2.3 dB);
       17-ab-unit src +0.40 -> film +0.30 LU (content +1.2 dB)
[ ok ] content: best-matching stage 0.39 vs worst-matching control 0.03
       (separation 11.8x over 6 blind windows) -- the film says its script
```

## Chapters

Computed from the **actual durations of `out/segments/*.mp4` in `_all.txt`**, not
from `timeline.json` (which has gone stale across rebuilds three times).

```
0:00  Title card (DAW Pro / History)
0:04  Beethoven wrote the numbers down
0:40  What a metronome mark actually says
1:11  What it does NOT say
1:55  How many marks, how many disputed
2:22  The mark in the app: 108 becomes 216
2:55  The eight notes everyone knows
3:46  The fermata, and what we are not measuring
4:21  Checking the clock before timing anything
5:10  Why the timing is read off the metronome
5:47  The mark, as he marked it
6:22  The study that measured it
7:05  Marked against performed
8:20  Two metronomes, ten seconds
9:11  Explanation one: the machine was broken
9:44  The Eroica, and a fixed rate
10:50 Explanation two: the scale was misread
11:27 Explanation three: the wrong note value
12:13 The same number, twice
13:17 The Ninth, still argued
13:54 What is not settled
14:26 Nobody knows why
15:05 End
```

## Two numbers that are outside the brief's bands, and why

**15:08 against an 11–14 minute band.** Not trimmed. The brief's band describes
what the previous six rebuilds happened to produce; the user's standing
direction is that *"the quality is what should define how much time we need for
learning"*. The candidate trim was halving the A/B cycles (≈ 55 s, landing
14:13), and every second of that is a demonstration the viewer listens to.
Measured from the segment durations in `_all.txt` (sums to 908.20 s): **736.64 s
of explanation, 164.56 s of listening, 7.00 s of title cards**.

**−17.4 LUFS against a −16 house figure.** Siblings measured −14.6 (comma),
−16.1 (amen), −16.4 (bach-house), −16.7 (mono-bass, beethoven-128), −17.2
(chasing-14) — so this is 0.2 LU past the quietest sibling. The mechanism is
known and is not drift: the talk segments are loudnorm'd and measured **−16.1 to
−16.7** across all 21 of them, but five demo blocks carry `normalize=False` on
purpose (loudnorm would destroy an A/B whose whole point is a level and tempo
difference) and those sit at **−18.1 to −20.5** integrated. 165 s of deliberately
un-normalised material under a −16.4 talk floor pulls the integrated figure
down. Raising them would either flatten the A/B or push peaks past the ceiling.
Nothing was trimmed to chase a number.

## Audibility — the thing that was nearly shipped inaudible

The brief requires checking a demo can actually be heard. **Peak and integrated
loudness both gave the wrong answer here, in opposite directions**, and the
disagreement was the signal:

| | click demo | narration |
|---|---|---|
| sample peak | **−3.0 dBFS** | −4.5 dBFS |
| max momentary (400 ms) | **−23.7 LUFS** | −11.6 / −12.1 LUFS |

By peak the metronome was *louder* than the voice. By momentary it was **twelve
LU under it** — and momentary is the measure that matches a laptop speaker. A
20 ms woodblock at −3 dBFS is not as loud as sustained speech. A metronome is
mostly silence, so plain gain could not fix it: 3 dB of headroom against 12 LU
of deficit.

Fix: a **tanh soft clip at +8 dB into a −1.0 dBFS ceiling**, swept over 7–11 dB.
What makes it legitimate rather than a fudge is `soft_lift()`'s control — it
re-runs the onset probe on the lifted file and **refuses if any tick moved**:

```
lift demo-bothclicks  +8.0 dB -> peak -1.321 dBFS, 32 ticks, max shift 0.0 ms
lift demo-sameclick   +8.0 dB -> peak -1.321 dBFS, 18 ticks, max shift 0.0 ms
lift demo-click       +8.0 dB -> peak -1.321 dBFS, 16 ticks, max shift 0.0 ms
lift ab-eroica-a      +8.0 dB -> peak -1.321 dBFS, 16 ticks, max shift 0.0 ms
lift ab-eroica-b      +8.0 dB -> peak -1.321 dBFS, 11 ticks, max shift 0.0 ms
```

Measured on the **finished film's own segments** (`filmcheck.py` check 4, now
part of the retained chain rather than a scratch file):

```
voice reference (max over 4 talk segments): -11.3 LUFS momentary
05-notes-play        -15.2   3.9 LU under voice
07-calibrate-play    -17.7   6.4 LU under voice
12-marker-play       -17.8   6.5 LU under voice
16-hyp3-play         -17.8   6.5 LU under voice
14-eroica ab halves  -17.8   6.5 LU under voice
11-ab-tempo halves   -17.0   5.7 LU under voice
17-ab-unit halves    -17.0/-17.3   5.7-6.0 LU under voice
CONTROL: 8 distinct momentary values across 20 files
```

Everything is now within 6.5 LU of the voice, where it was 12. The control
matters: a **single uniform value across 20 files would mean the probe is
broken**, not that the mix is even.

## The subject is DISPUTED and the film does not resolve it

`docs/lessons/PROGRAM.md` marks this **(DISPUTED)** and that governs the whole
script. Three explanations are presented, each with its evidence and its named
defenders, and **none is endorsed**. `19-settle` refuses in as many words and
`20-close` ends on "nobody knows".

Two corrections to the shipped film's facts, found by transcribing it:

* It pairs **half = 108** (the *first movement*'s mark) against **Schuller's
  ~92**, which is the mean of 66 recordings of the ***finale***. Different
  movements. Both Schuller's 92 and the Stokowski ~40 are cut from this
  rebuild; the comparison now uses **PLOS ONE 2020's ~12–13 bpm average
  shortfall**, and the film says out loud that subtracting 12 from *this one
  mark* is my arithmetic applied to *their* average, not their finding about
  this movement.
* It says "**108 beats a minute**" where the mark is 108 **half notes** — the
  exact imprecision this rebuild's spine (score 108 / app 216) exists to
  correct.

The broken-metronome hypothesis is presented as **untestable here**, and the
film says so: the weight is missing from the surviving instrument. A jitter
render exists in `audio/` but is used **only as the onset probe's positive
control** — building it into a demo would have meant inventing a mechanism.

## What is measured, and the control on each

Every figure the voice says comes from `MEASUREMENTS.json`, written by
`measure.py` **before** any rendering, with predictions computed in `predict()`
before a single audio file is opened.

| measurement | value | its control |
|---|---|---|
| tick interval at half = 108 | **555.5558 ms** measured vs 555.5556 predicted | wrong-BPM mutant → "TICK RATE WRONG" |
| spread across a whole render | **0.0208 ms** = one sample at 48 kHz | blunted fine pass → "disagree by 5.61 ms" |
| jitter render (probe control) | audio **5.4236 ms** vs project **5.4172 ms** | synthetic 14 ms swing recovered as 14.00 |
| drift per tick, 216 vs 192 | **69.4 ms** | predicted vs measured per statement |
| two metronomes in 10 s | **32** distinct onsets, one alone has **18** | gcd arithmetic: 9 ticks against 8, period exactly 5.000 s |
| half/quarter music ratio | **2.00000** (2.22 s → 4.44 s) | material NPS crosscheck |
| held GM string chord envelope | **9.7 dB** range, **76** turnarounds/s | this is *why* timing is read off the woodblock |

## ⭐ Found by looking, after everything had already passed

This section is the point of the report. Every item below sat inside a fully
green build.

### 1. A "0 differences across 3124 words" that compared nothing

The word-by-word transcript diff the brief requires returned **zero differences
across all 21 stages** — a beautiful result. `out/build-report.json`'s
`narration` list is **empty** when the build ran `--skip-narrate`, so the loop
iterated over nothing and reported perfection.

Re-done by transcribing the 21 VO wavs that are actually in the film: **94 diff
blocks**, which is a probe that works.

### 2. The whole-file transcript inverted an attribution the sentence exists to make

In `10-plos` the script says:

> …it is my arithmetic and not their finding. **They** measured an average
> shortfall across everything. I am taking twelve off this one mark…

Whole-file Whisper heard "**I have** measured an average shortfall across
everything" — claiming the study's finding as my own, in a lesson about not
overclaiming, at similarity 0.877 with the gate green.

**Two instruments disagreeing was the signal.** Transcribed twice more over a
short window: both returned "**They** measured". The audio is correct; the
long-file pass was wrong. Same artefact hit the brand check — the 36.8 s open
window transcribed "DAW**B** Pro" while an 11 s window over the same audio
returned "DAW Pro" cleanly.

### 3. Three genuine TTS mangles the similarity gate passed at 0.93–0.97

Each confirmed at the source with a short window, then fixed by rewording, then
**re-confirmed at the source**:

| script | TTS said | now |
|---|---|---|
| "Sture Forsén and colleagues" | "**Sturer** Forsen" | "Forsén and colleagues" — surname citation, and it now matches the card |
| "the best **evidenced** of the three" | "the best **evidence** of the three" | "the one with the most evidence behind it" |
| "the second **as** quarter notes" | "the second **is** quarter notes" | "the second **is read as** quarter notes" |

An aggregate similarity score cannot see any of these.

### 4. A card that cut away three seconds before its own numbers were spoken

`10-plos` had `shots=[8, CH_DRIFT], cut=5.6` over a 43.5 s stage. The still timer
is `n = round(total/cut)` with each slot `total/n`, so that is **eight** slots of
5.44 s and card 8 — the card reading *"36 recordings / 9 symphonies, 36
conductors, PLOS ONE 2020 / about 12 beats slower"* — was **gone at 5.44 s**.
The numbers are spoken at **8.4 s, 9.7 s and 11.8 s**, over the drift chart.

This is the defect class the brief names as having shipped twice. It is now
`cut=14.5`, and a frame pulled from the deliverable at the moment "a hundred and
sixty nine hours" is spoken shows the study card.

`slotcheck.py` was written to find this class generally: it reproduces
`assemble.py`'s slot arithmetic, estimates when each phrase is spoken from its
word position, and prints the `ffmpeg` line to pull that exact frame.

### 5. A predicted defect that was not one, and a real one arithmetic could not see

The same audit predicted `04-tempofield` would show the wrong crop when "two
hundred and sixteen" is spoken. **The frame disproved it** — the ruler crop
shows `4/4 / 216` legibly at exactly that moment.

But pulling the frame found a different defect the arithmetic had no way to see:
`ZTEMPO`'s crop `[0.20, 0.72, 0.28, 0.28]` was **two-thirds empty black**,
because the transport bar is the bottom ~8 % of the window. Retested against the
3200×1800 source and moved to `[0.30, 0.845, 0.20, 0.20]`; 0.15 was tried and
rejected as a 5× upscale that is visibly soft and clips TIME mid-digit.

**The prediction was wrong in kind. The frame pull was right for a reason nobody
predicted.**

### 6. A manim caption printed under the burned-in corner meter

Both manim scenes had already been fixed by pulling **manim** frames. But the
corner meter is burned onto the film **after concat**, so no manim frame can ever
show a collision with it. Pulled from the deliverable, `anim_unit`'s closing
caption ran its last words — "half the **speed:**" — straight under the meter
box. Rewritten as two shorter lines shifted to x = −1.05, re-rendered, rebuilt,
re-pulled: clear. `anim_drift`'s captions are top-anchored and were fine, checked
the same way.

### 7. A positive control that never ran and looked exactly like a passing one

Mutation-testing the new spoken-number gate, control B ("move the words, keep the
fact") **passed** — i.e. failed to fire. The `sed` had matched nothing: the
phrase spans a line break in the source (`"…over a "` `"hundred and sixty nine
hours…"`). Re-aimed at the real source text, it fired.

A control that never applied and a control that applied and found nothing produce
identical output.

### 8. My own unfalsifiable check, caught before it shipped

The first version of the hours check was `check(169, FACTS["plosHours"])` — a
literal against a literal, exactly the `C["snareGhost"] + 1` shape the brief
names. `plosHours` is spelled out **in words** in the narration and interpolated
nowhere, so nothing tied the two together.

Replaced with `spoken_int()`, which parses the English spelling back to an
integer, plus `check_says()`, which asserts the words are in that stage's
narration. Both were then **made to fail on purpose**:

```
control A (move the fact):  SPEC REFUSES TO BUILD ... the voice says
                            'a hundred and sixty nine' = 169, the fact sheet says 170
control B2 (move the words): SPEC REFUSES TO BUILD ... 10-plos does not say
                            'a hundred and sixty nine hours'
control C (unreadable):     SPEC REFUSES TO BUILD: cannot read the spoken number
                            'a hundred and sixtyish' -- unknown word 'sixtyish'
negative control:           untouched spec builds clean
```

`check_says` also fired on its very first real run: it asserted "thirty six
recordings" when the narration says "thirty six **complete** recordings". The
probe was fixed, not the gate.

### 9. I wrote "pulled and read" about two frames I had only pulled — and one of them held a defect

Drafting this report I listed frames at 513.0 s and 590.7 s as "pulled and read".
Both had been **extracted and never opened**. Reading them properly found:

* 590.7 s — fine. `chart-hypotheses.png`, "76" legible exactly as spoken.
* 513.0 s — **the same defect as §4, in a different stage.** `12-marker` ran
  `shots=[DRIFT_MID, DRIFT_FIN], cut=6.5` over 38.4 s, so the mid still was gone
  at 6.4 s. But the mid still is the one whose captions read *"they come apart by
  69.4 ms every tick"* and *"two attacks stop sounding like one at about 30 ms"* —
  and the voice says those two numbers at **12.6 s and 17.2 s**, by which point
  the final still was up, captioned *"32 separate ticks"* instead.

Fixed at `cut=19.2` and re-pulled from the rebuilt film: "69.4 ms" is on screen
when it is spoken.

**Pulling a frame is not reading it, and an unread frame in a checklist looks
exactly like a read one.** The defect had survived a fully green build, a
slotcheck pass, and my own summary saying it had been checked.

### 10. Earlier in the build, same shape

* **The onset probe missed the tick at t = 0** in every file — 15 of 16, 31 of
  32. Tidy, uniform, plausible, wrong: `np.diff(..., prepend=env[0])` produces no
  rise at the first frame. Fixed by front-padding 40 ms.
* **The probe quantised to its own 1 ms hop**, returning the mark's tick as
  alternating 556/558/553 ms — a 5 ms "spread" that belonged to the probe. A
  second 1-sample-hop pass gives 0.0208 ms.
* **A `[:WANT]` slice** made the found-vs-expected count check unfalsifiable; it
  passed while returning a 2:1 ratio as 1.08.
* **String onsets were nonsense** (64–90 candidates for 32 notes). Rather than
  guess, the mechanism was measured — 9.72 dB of envelope movement, 76
  turnarounds a second from detuned layers beating — and the finding became an
  on-screen chapter, with all timing moved to the woodblock stems.
* **An `awk` momentary probe returned an identical 0.0 for six files.** A tidy
  uniform result across many units is a broken probe.
* **`zoom` is fractions 0–1, not pixels** (`assemble.py::_crop_expr`). This one
  failed loudly, which is the good case.
* **The Eroica A/B cut through a ringing click** at 8.0 s (−23.7 dB of peak);
  swept 7.0–15.0 s and moved to 8.6 s, where both halves sit in digital silence
  for the last 60 ms.

## Verification done on the deliverable itself

* **Brand transcribe-back** on `out/L7v2.mp4` (not the wavs): open **FOUND**
  (windowed; see §2), close **FOUND**, and a **music-only negative control** at
  460.4–470.4 s returned `'BATHRyk'` — no brand string.
* **Frames pulled and opened** at the moments numbers are spoken: 148.6 s (tempo
  field), 154.3 s (216 on the ruler), 269.2 s (555.5556 ms on the clock chart),
  386.5 / 391.7 / 393.8 s (the study card), 513.0 s (69.4 ms on the drift chart,
  **after the §9 fix**), 590.7 s (76 on the hypotheses chart), 733.3 s (unit
  chart caption clear of the meter), and 2.0 s (**intro carries no corner
  meter**, as the editorial rule requires).
* **Per-segment loudness sweep** over all 38 segments: −20.5 to −16.1 LUFS.
* **Cut quality** on all 19 demo segments: −27.5 dB to −inf below own peak,
  against a deliberate mid-hit positive control at **−0.18 dB**.
* **Chapters** recomputed from `_all.txt`, not `timeline.json`.
* **A/V drift moved 11.7 → 25.0 ms** across the three re-narrated stages. Still
  under one frame at 30 fps (33.3 ms) and the gate passes, but a future rebuild
  that re-narrates more stages could cross it — worth watching, not fixing now.

## Staging, restored and proved by re-reading

Built on **staging 17695** (`DAWApp` pid 74267). Port 17600 — the user's live app
— was never contacted; `dawctl.mjs` defaults to 17600, so both `DAW_CONTROL_PORT`
and an explicit URL were set on every call.

Read back from `project.overview` after the build, against `media/shoot.json`:

| | shoot recorded | read back now |
|---|---|---|
| tempo | 216 | **216** |
| master volume | 1 | **1** |
| tracks | Strings (1 clip), Click (1 clip) | **Strings (1 clip), Click (1 clip)** |
| mute / solo | none | **none** |
| transport | — | **stopped, position 0** |

`debug.panelLayout` read back with no panel left open: `humanizePanelVisible
false`, `editorMaximized false`, `editorFraction 0.43`, `pianoRollPPB 55`,
`rowHeight 50`. ⚠ Honest limit: the shoot recorded tempo/master/tracks but **no
panel baseline**, so this is an absolute check that nothing was left open, not a
before/after comparison.

Project saved under its own name, `media/Metronome lesson (staging scratch).dawproj`.

Speech server: launched on a per-shell port, killed **pid-exact**, and the port
proved free afterwards.

## Repository hygiene

`.gitignore` checked **both ways** with `git check-ignore -v`:

* ignored as intended — `out/` (671 MB), `audio/*.wav` (135 MB), `shots/`
  (4 MB), `media/`, `bursts/` (254 MB); **1.0 GB total on disk**
* *not* ignored — every source file

`git status --short --untracked-files=all` on this directory lists **13 source
files** (plus this `NOTES.md`, making 14), no heavy artefacts. Nothing was staged
or committed; HEAD is unchanged at `56e26b1`.

## The build chain (retained, in order)

| file | what it does |
|---|---|
| `material.mjs` | the single home for the material and every tempo; documents which historical numbers are sourced and which are deliberately excluded |
| `shoot.mjs` | builds the project on staging, renders every wav, captures stills and bursts, saves the project |
| `measure.py` | predictions first, then measurement; onset probe, tick report, string envelope, A/B pairing, `soft_lift`, crosscheck → `MEASUREMENTS.json` |
| `charts.py` | four charts, every point read from `MEASUREMENTS.json`, with the footnote/meter keep-out gate |
| `anim_drift.py` | the attention marker — real-time playhead over two measured tick rows |
| `anim_unit.py` | the mechanism — one tick row, two readings |
| `bursts.py` | renders both scenes, relays the beds, copies stills into `shots/` |
| `spec.py` | 14 cards, 21 stages, 3127 words, ~42 `check()` assertions → `L7v2.json` |
| `slotcheck.py` | **which still is on screen when each number is spoken** |
| `filmcheck.py` | four checks on the deliverable beyond `verify.py`'s eight |

Rebuild — the invocation actually used, venv python and speech server included:

```bash
export OMLX_PORT=$((8000 + ($$ % 900) + 1))
export OMLX_BASE=http://127.0.0.1:$OMLX_PORT
$V/omlx serve --port $OMLX_PORT & OMLX_PID=$!      # kill only this pid afterwards
P=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
$P spec.py
$P ../../shortsmith.py L7v2.json --out-dir $PWD/out   # add --skip-narrate to reuse the VO cache
$P slotcheck.py && $P filmcheck.py out/L7v2.mp4
```

⚠ `verify.py`'s content check transcribes the film, so the speech server has to
be up even for a `--skip-narrate` build.
