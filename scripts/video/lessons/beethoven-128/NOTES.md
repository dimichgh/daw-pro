# Lesson 11 rebuild — Beethoven at 128

Film 3 of the 8-film rebuild wave. Nothing of the original survived except
`~/Movies/DAW Pro Lesson 11 - Beethoven At 128.publish.json` (title, tags,
description). Every number below was measured off **renders made in this
session**; the shipped description's figures were treated as claims to be
re-tested, not data to be quoted — and one of them did not survive the test.

## The film as built

`out/L11v2.mp4` — **796.2 s (13:16)**, 1920×1080 h264 / 48 kHz AAC stereo,
**44,355,170 bytes (42.3 MB, `wc -c`)**, `−16.7 LUFS / −1.2 dBTP` (verify.py).
**NOT finalized, NOT published.** The spec's `filename` is
`DAW Pro Lesson 11 - Beethoven At 128 (rebuild)`, deliberately different from
the shipped file, so even a stray `--finalize` could not overwrite it.

Eighteen chapters, **614.9 s of explanation against 174.2 s of demonstration**
(`out/segments/*-mux.mp4`, ffprobe). Chapter starts include the 4 s intro; the
A/B halves' absolute positions are in `out/L11v2.mp4.timeline.json`.

```
0:04  00-open        6:17  10-versions   A/B orchestral vs techno
0:42  01-motif       7:12  11-spectrum   ← the centrepiece
1:16  02-cell        7:52  12-bands
2:22  03-development 8:41  13-marker
2:54  04-techno      9:36  14-laptop     A/B full-band vs high-passed
3:23  05-honest     10:49  15-proxy      A/B sub as written vs two octaves up
4:00  06-project    11:59  16-loudness
4:36  07-orch       12:29  17-close
5:07  08-techno
5:40  09-build
```

⚠ Within a stage the ORDER IS TALK THEN PLAY, not play then talk. Derived, not
assumed: cumulative `-mux` durations under that ordering reproduce
`timeline.json`'s `10-versions` ab0 start (400.153 s) and `14-laptop` ab0 start
(617.153 s) **to 3 ms**; play-first mis-predicts both by exactly one talk
segment.

`verify.py` — **all 8 checks ok**, including `A/B separation`:

```
10-versions src +0.40 -> film +0.50 LU
14-laptop   src +6.40 -> film +6.40 LU
15-proxy    src -5.80 -> film -5.80 LU
```

Content gate: best-matching stage **0.33** against a worst-matching control
**0.03** — a **10.9× separation** over 6 blind windows, with the omlx speech
server up on 8000 for the whole build (it was started before shortsmith and
killed pid-exact, 96448, afterwards; `lsof -nP -iTCP:8000` empty after, with
17695 still listening as the positive control that the probe works).

## THE FAULT, AND WHAT I DID ABOUT IT

The brief: the shipped film's whole argument lives below 100 Hz, the band a
MacBook Pro speaker barely reproduces, so the viewer cannot verify it. And the
warning from film 1: **do not treat "reduce the sub-100 Hz share" as the goal** —
that metric measures the subject, not the fault.

So I did not chase the metric. I re-tested the claim, and it broke.

### The headline claim does not hold on honestly-voiced material

The shipped description says the orchestral version sits at −47.2 dB below
100 Hz and the techno version at −29.4 dB — "about 18 dB of fundamental an 1808
orchestra could not produce". On my renders (`measure.py`, Welch PSD, band
integration):

| band | orchestral | techno | techno − orch |
|---|---|---|---|
| under 40 Hz | -55.25 dB | -23.63 dB | **+31.62** |
| under 60 Hz | -54.41 dB | -21.11 dB | **+33.30** |
| **60 – 100 Hz** | **-27.70 dB** | **-28.30 dB** | **-0.60 — the ORCHESTRA is louder** |
| under 100 Hz | -27.69 dB | -20.32 dB | +7.37 |
| 100 – 200 Hz | -26.85 dB | -30.14 dB | -3.29 |
| above 200 Hz | -26.35 dB | -35.15 dB | -8.79 |
| the whole file | -22.11 dB | -19.74 dB | +2.38 |

Below 100 Hz the two versions are **7.37 dB apart, not 18**. The two spectra
**cross at 73.2 Hz**, and between 60 and 100 Hz the orchestra is the louder of
the two — because a double-bass section genuinely fills that band; that is what
a double bass is for. The real gap is **+33.30 dB below 60 Hz** and **+31.62 dB below 40 Hz**
(the 40 Hz figure is the SMALLER of the two because the sub part's two pitches,
32.7 Hz and 49 Hz, straddle 40 Hz — half of it is above the 40 Hz line).

I could not reproduce 18 dB on a double-bass part that is voiced honestly. I
have not seen the original's session, so I cannot say what produced it; I can
only say what mine measures.

So the rebuilt film argues a different thesis: an orchestra is not bass-less.
**It has a floor.** The floor is a piece of wood with a string on it, and
essentially the whole difference lives underneath it.

⛔ **THE FILM DOES NOT NAME THE FIGURE IT REPLACES — THAT IS A RULING, 2026-09-05.**
An earlier cut of 12-bands said *"The version of this film I am rebuilding
claimed eighteen, and on this material that is not true,"* and card 9 carried
the same referent. Both are **cut**, on the coordinator's ruling, for two
reasons; the second decides it:

1. **A viewer has no referent.** This rebuild replaces the original at the same
   title, so to the audience there is no "version I am rebuilding" — the
   sentence makes the film about our production process instead of about
   Beethoven and bass, and a novice just gets confused about which film they
   are watching.
2. **"Not true" overstated the evidence.** I measured MY renders of MY
   arrangement. That can say what THIS material does; it cannot show an earlier
   figure was wrong about its own. Asserting the stronger claim is exactly the
   overreach this whole standard exists to prevent.

The replacement is the positive statement, which needs no comparison to stand
up: **under 100 Hz the two are about seven decibels apart; between 60 and 100 Hz
the orchestra is if anything marginally louder; essentially the whole difference
lives below sixty hertz.** I also cut an intermediate clause of my own —
"seven, not the twenty or thirty you might expect" — because "twenty or thirty"
was a number I never measured: the old claim's magnitude smuggled back in as a
rhetorical expectation.

⭐ **The finding itself was independently reproduced by the coordinator** with
their own Welch implementation: `<40 +31.33` (mine +31.62), `<60 +33.06`
(+33.30), `60–100 −0.58` (−0.60), `<100 +7.28` (+7.37), `>200 −8.79` (−8.79
exactly). Their first pass, with ffmpeg `lowpass`/`highpass`, disagreed badly on
the narrow bands — 2nd-order filter skirts leaking — which is a useful reminder
that the 6th-order `sosfiltfilt` in `measure.py` is doing real work. Two
instruments agreeing is the signal.

**Verified in the finished film, not just in the script.** The 12-bands take
transcribes with **no** "rebuild" / "version of this film" / "i am rebuilding"
substring, and **does** contain "below 60" — the positive control that the
replacement sentence is actually there, so the absence means something.
Own-script similarity **0.904** against **0.139** for the neighbouring stage's
script; the build gate scored it `take 1 sim 0.96  facts OK (4)`, a fourth fact
having been added to pin the new load-bearing sentence. Card 9 and the chart
were re-pulled from the finished mp4 at 476 s and 505 s and looked at: card 9
now reads "below 100 Hz — only +7.4 dB apart" with no referent, and the meter is
clear of every axis label.

### Treatment 1 — carry it visually (the centrepiece)

`shots/chart-spectrum.png` (stage 11, `holdLast=True`): both renders' Welch PSDs
overlaid, log frequency, with the **sub-60 band shaded**, the ~41 Hz bass-bottom
line dotted and the 73.2 Hz crossover dashed. Supported by
`chart-bands.png` (the table above as bars growing up from a −60 dB floor, with
the 60–100 Hz counter-fact visible as a bar that goes the wrong way) and by
`anim_time.py` — a real-time playhead sweeping the techno render's first 12 s
with the **<60 Hz trace against a >100 Hz control**: the sub's arrival lifts the
bottom band **+44.52 dB** while the control band moves **−0.83 dB**. The shaded
window is derived (every stretch >15 dB above the pre-sub baseline, gaps <150 ms
merged, <250 ms dropped), never chosen by eye.

### Treatment 2 — an audible proxy, measured before it was claimed

**(a) The laptop A/B (stage 14).** High-passing at 100 Hz costs the techno render
**9.78 dB of RMS but only 6.20 LU of measured loudness**; the same filter costs
the orchestral render **1.43 dB / 1.10 LU**. So the film can say something true
and checkable on any speaker: *playing the techno version on a laptop is a fair
imitation of what the orchestra was doing about the bottom octave anyway* — the
orchestra barely used the band the laptop is throwing away.

**(b) The octave-up proxy (stage 15).** The sub part alone, then the same part
transposed two octaves (32.7/49 Hz → 131/196 Hz). Moving it changes overall level
by **+0.01 dB** and its content above 100 Hz by **+51.70 dB**. The film states
plainly that this is a proxy and not what the record sounds like.

### Treatment 3 — say what the speakers will and will not give you

Card 10 (`9.8 DB OF LEVEL`) and card 13 (`IF YOU ARE ON LAPTOP SPEAKERS`),
plus a paragraph in 00-open. **A statement, never a gate and never the viewer's
fault** — the last line of card 13 is "that is not your fault / and it is why
all of it is drawn as well as played".

## Historical honesty

The techno repetition is **the film's own invention**, said as such in 03/04.
The film does not touch the metronome-mark dispute at all (lesson 7's subject).

Two history claims were softened after review, because as first written they
were contestable stated as fact:

* "the lowest note a double bass of 1808 could physically play — 41.2 Hz" →
  "**about forty one hertz, the bottom string of a double bass**", with the film
  adding that some Viennese basses of the period were strung differently and
  stopped higher, so the line is approximate. (The chart caption and card 8
  match.)
* "nobody in 1808 could build a thing that would go there" → "**the orchestra he
  wrote this movement for has no instrument that reaches down there.** Not that
  nothing in 1808 could reach it. A big church organ went far lower, and
  Beethoven himself brings in a contrabassoon for the finale of this very
  symphony, which goes below that line too. Neither of them is in the movement
  this lesson is built on, and that is the whole point." The original wording was
  simply false — 16′ and 32′ organ stops long predate 1808 — and an intermediate
  draft that said a contrabassoon merely "gets close" was also wrong: it sounds
  an octave under the bassoon, well below 41 Hz. The claim that survives is about
  THIS movement's scoring, which is the claim the measurements support.

## The material

Hand-written in `material.mjs` — **no generation model was used for any of it**.
One four-note cell, `n(+0.5) n(+1.0) n(+1.5)` on a high pitch then a 1.9-beat
note lower, phrase `[G2 E♭2] [F2 D2] [G2 E♭2] [A♭2 G2]`, 16 bars at 128 BPM
(64 beats, 30.0 s). **402 notes**: 64 riff notes ×3 octaves orchestral, 64 for
the techno riff, 134 drum hits, 12 sub notes.

Both versions live in **one project** and play **the same 64 notes** — the
orchestral render silences the techno tracks and vice versa, via
`render.bounce { excludeTrackIds }`. So the only variables are instrument and
arrangement, which is exactly the question the film asks. Volumes were chosen
from stem bounces in `probe.mjs` (retained as prior art).

**Loudness control:** orchestral **−19.90 LUFS**, techno **−20.90 LUFS** —
**1.00 LU apart**, measured twice (the app's own render report and ffmpeg
`ebur128` afterwards) agreeing to 0.01–0.02 LU. None of the difference the film
shows is a loudness trick.

## Build chain

```
node material.mjs         # (imported; no side effects)
node probe.mjs            # stem bounces -> the volume choices
node shoot.mjs            # project, stills, 17 renders, 3 captureUI bursts
node record.mjs           # the ONE screen recording (--app DAWApp)
measure.py                # MEASUREMENTS.json + spectra.npz + every A/B wav
charts.py                 # 5 charts into shots/
bursts.py                 # manim scenes + screen rec -> bursts/ + beds
spec.py                   # -> L11v2.json  (15 cards, 18 stages, 2574 words)
../../shortsmith.py L11v2.json --out-dir out     # NO --finalize
```

Everything heavy that is generated (`out/`, `bursts/`, `manim/`, `media/`,
`*.wav`, `shots/`) is already covered by `.gitignore` lines 69/85/100–103, which
the mono-bass pilot added — checked with `git check-ignore -v`, which named the
matching rule for each. The retained chain (`*.mjs`, `*.py`, `L11v2.json`,
`MEASUREMENTS.json`, `NOTES.md`) is NOT ignored and is committable; neither is
`spectra.npz` (388 KB, regenerable by `measure.py`). Same as the two reference
rebuilds, **none of which is tracked either** — `git ls-files` on both returns
nothing. I committed nothing.

## Traps hit, in the order they bit

1. **`track.setInstrument` refuses a nested `polySynth` object.** The wire takes
   `waveform`/`attack`/… as TOP-LEVEL keys. Documented at the `poly()` helper.
2. **`track.setMuted` does not exist** (it is `track.setMute`). Rather than
   patch it I switched the whole approach to `render.bounce { excludeTrackIds }`,
   which measures AND writes without mutating the project at all.
3. **The websocket keeps node's event loop alive.** `close()` alone hangs
   forever at 0 % CPU with every render already on disk (killed pid-exact,
   92636). Every script here ends `close(); process.exit(0);`.
4. **stdlib `wave` cannot read float wavs** (`unknown format: 3`). Everything
   uses `soundfile`.
5. **The first attention-marker design was useless.** Orchestral-vs-techno below
   60 Hz derived ONE window covering the whole excerpt with nothing left
   unshaded — a marker that marks everything marks nothing. Redesigned around the
   techno version's own first 12 s (layer arrivals) with >100 Hz as a control.
6. **`highLiftDb` came back `nan`** because its control window
   `(t > clap−2.0) & (t < sub−0.2)` was empty. Moved between the hats and the
   sub, with the "after" window stopped at the clap so the clap cannot confound
   it.
7. **The `orchplay` burst was shot from beat 0 while `play-orch.wav` is cut at
   15.0 s (beat 32).** Footage of bars 1–4 under bars 9–12. Re-shot; the first
   frame's transport readout now reads POSITION 9.1 / TIME 0:15.000, matching
   `technoplay` exactly.
8. **The screen recorder's first frame is 366 ms into the music** (read off
   `media/_first.png`; last frame 0:13.070). `play-buildrec.wav` is cut from
   `techno.wav` at 0.366 s so the eye and the ear agree on where each strip
   arrives.
9. **`play-cell.wav` contained the kick.** Cut from `techno.wav` 0–3.75 s it
   included bar 2 at 1.875 s, while the animation over it draws nothing but the
   cell and the narration says "you are hearing the cell itself". Re-cut from
   `l1-riff.wav`. Proven, with a control that discriminates: best-fit residual
   against `l1-riff` **0.003 % of peak**, against the mix **120 %**.
10. **The assembler burns a level meter into the bottom-right corner**, and on
    two charts it ate the rightmost x-axis tick label ("above 200 Hz"). Measured
    the meter box off the finished film — **x 1480–1885, y 985–1045** — and gave
    `chart-bands` and `chart-proxy` `bottom=0.11`. Re-pulled the same frames and
    looked: meter now on empty background, every label readable, and the
    `AFTER` badge no longer sits over the proxy bars. **No gate saw this. Only
    looking did.**
11. Chart defects found the same way and fixed before the build: the spectrum
    stat block drawn through the curve, two captions overlapping each other,
    bands delta labels drawn INSIDE the bars, the legend over the last pair, a
    −62.4 dB bar missing under a −45 floor, the proxy caption behind the bars,
    and a manim inline legend drawn straight through both curves.
12. **`15-proxy`'s A/B used the same still for both halves**, which reads as a
    frozen video. `afterShots` now points at the proxy chart.

## Judgment calls made while the user was asleep

* **Rewrote the thesis** rather than reproduce an 18 dB figure I could not
  measure. I first had the film name the number it was replacing; I flagged that
  line as needing a ruling, and the ruling cut it (above). The film now states
  only what it measured.
* **Softened two history claims** (above) even though neither was flagged.
* **Kept the film long** (13:16). Eighteen chapters is more than the brief asked
  for, but the audibility problem needs three treatments and each needs setup.
* **Did not use any generation model** for material, per the standing rule.
* Reserved bottom margin on two charts instead of moving the meter, because the
  meter position is the house style and the charts are mine to change.

## What I could not do / known weaknesses

* **The per-take narration similarity scores were lost, then RECOVERED.** The
  first build ran without `-u` under a harness that captured 0 bytes of its
  block-buffered stdout; the log was overwritten by the cached re-runs and
  `out/vo/_cache.json` stores only hashes, so `build-report.json`'s
  `"cached", 1.0` for all 18 is a **placeholder, not a measurement**. I
  re-measured them directly instead: transcribed all 18 `out/vo/*.wav` with the
  same whisper-large-v3-turbo server and scored each against its own script with
  the same word-level `SequenceMatcher(autojunk=False)` verify.py uses (identity
  control asserted first). **18/18, own-script 0.886 – 0.997, median 0.956**,
  against **0.058 – 0.171** for the same take scored against a different stage's
  script — the negative control that makes the first number mean something.
  Written to `out/vo-scores.json`. (That file predates the 12-bands re-record
  described under "Historical honesty"; the replacement take's own gate score is
  in the build log — `vo : 12-bands take 1 sim 0.96  facts OK (3)` — so the
  measured range is unchanged.) The six takes under 0.91 are all the
  number-heavy stages; diffing the worst (12-bands, 0.886) shows **every single
  mismatch is the documented digit/word artefact** — "one hundred hertz" heard
  as "100 Hz", "six tenths of a decibel" as "0.6 dB", "eighteen oh eight" as
  "1808". No word is wrong.

* **Spot transcription of the deliverable**, whisper-large-v3-turbo via the same
  server: window 24–40 s returns "DAW Pro. It is all built in DAW Pro…" —
  brand correct, twice. **Negative control**, window 700–716 s: "One last
  control, because the comparison between two mixes…" — no brand string, so the
  probe discriminates. (A first pass appeared to garble the closing clause; a
  wider window, 33–45 s, returns it verbatim — the garble was a whisper artefact
  at the window edge, not the audio.)
* **The hats stem measures −44 LUFS and the `+hats` rung moves the mix by
  0.0 LU** on `chart-layers.png`. Offbeat hats at bar four are too quiet to earn
  their own rung. I did not re-render, because every number in the film comes
  off these renders and re-voicing one part would move all of them; the chart
  shows the flat rung honestly rather than hiding it.
* **The `technoplay` burst shows the BASSES piano roll**, not the Riff track,
  while the techno version is playing. Not false — `BASSES` and `RIFF` are the
  same 64 notes in `material.mjs`, so the pitches and rhythm on screen are
  exactly the ones sounding, and 08's narration says so out loud ("same bar
  positions as the double basses you just heard"). But it is inconsistent with
  `orchplay`, which is framed on the arrangement with no editor open. Found by
  looking at frame 335; left as-is rather than spend a re-shoot plus a rebuild
  on a frame that is truthful.
* **`render.bounce` loudness is reported to 0.1 LUFS** by the app, so the
  "1.00 LU apart" figure is 1.0 ± 0.05, not more precise than that.
* The staging session that was open before this work was saved to
  `…/scratchpad/staging-before-beethoven.dawproj` and **reopened and verified by
  re-reading**: tempo 100, tracks Pad / Bass / Drums / Lead, playhead 0, master
  volume 1, `warnings: []`. Port 17600 was never contacted; every command went
  to 17695 through `session/build.mjs`, which refuses 17600.
* ⚠ **I never captured the panel layout before changing it**, so the layout
  restore is to the APP DEFAULTS, not to what the user had. `shoot.mjs` drove
  `pianoRollPPB`, `pianoRollRowHeight`, `editorFraction`/`editorMaximized`, and
  `record.mjs` drove `followPlayhead`. Those five are now back at the defaults
  read out of `PanelLayoutModel.swift` / `PianoRollZoomModel.swift` — PPB 32,
  row height 14, fraction 0.45, unmaximized, follow OFF — **re-read to confirm**:
  `{"pianoRollPPB":32,"pianoRollRowHeight":14,"editorFraction":0.45,
  "editorMaximized":false,"followPlayhead":false,"rowHeight":50}`. `rowHeight`
  is left at **50** (the app default is 34) precisely because I never wrote it:
  that one is the user's own and guessing at it would be worse than leaving it.
  `pianoRollCenterPitch` is a one-shot scroll request, not persisted state
  (`DAWProApp.swift:5636`), so there is nothing to put back. The mixer is closed.
* **The music bed under the argument stages was verified, not assumed.**
  Dropping `bedEligible=False` from 07/08/09/10 was supposed to let 11-spectrum
  and 12-bands narrate over the techno loop rather than silence. Measured as the
  5th percentile of 100 ms RMS across each stage's `-mux` segment:
  **11-spectrum −31.5 dB, 12-bands −31.6 dB** (a continuous floor) against
  **16-loudness −41.4, 17-close −40.3, 07-orch −41.4 dB, minima −80 to −88 dB**
  (digital silence in the inter-sentence gaps). The control discriminates, so
  the bed is real.
