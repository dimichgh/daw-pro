# Lesson 5 rebuild — Bach House

Film 5 of the 8-film rebuild wave. Nothing of the original survived except
`~/Movies/DAW Pro Lesson 5 - Bach House.publish.json` (title, tags,
description). Every number below was measured off **renders made in this
session**; the shipped description's figures were treated as claims to be
re-tested, not data to quote — and two of them did not survive the test (see
"What the old description said, and what mine measures").

## The film as built

`out/L5v2.mp4` — **864.5 s (14:24)**, 1920×1080 h264 / 48 kHz AAC stereo,
**50,787,984 bytes (48.4 MB, `wc -c`)**, **−16.4 LUFS / −1.4 dBTP**
(verify.py), md5 `402236e87b4c6de5094fde2848778196`.
**NOT finalized, NOT published.** The spec's `filename` is
`DAW Pro Lesson 5 - Bach House (rebuild)`, deliberately different from the
shipped file, so even a stray `--finalize` could not overwrite it.

Seventeen chapters, **661.1 s of explanation against 196.3 s of demonstration**
(`out/segments/*-mux.mp4`, ffprobe). Chapter starts include the 4 s intro.

```
0:04  00-open         6:44  08-kick      + kick, app playing
0:48  01-terms        7:29  09-hats      + offbeat hats
1:28  02-prelude      8:17  10-clap      + clap on 2 and 4
2:18  03-figure       9:00  11-bass      + bass on Bach's roots
3:00  04-invariant ← the centrepiece    9:50  12-nested ← the grid picture
4:02  05-harmony     10:39  13-marker ← the attention marker
4:54  06-house       11:48  14-space     the measured band chart
5:36  07-tempo   A/B 72 vs 124          12:36  15-ab   A/B prelude vs track
                                        14:13  16-close
```

⚠ Chapter starts were derived from the cumulative `-mux` durations under the
house order TALK → A/B → PLAY, and the derivation was **checked against
`out/L5v2.mp4.timeline.json`**: it puts `07-tempo`'s first A/B half at
**378.444 s** and `15-ab`'s at **790.008 s**, which is exactly what the sidecar
records. The first pass of that arithmetic came out 33.1 s long because the glob
`15-ab*` matched `15-ab-talk-mux.mp4` in both the talk list and the "-ab" list
and counted it twice; the corrected total is 861.45 s + 3.0 s outro = **864.45 s**
against ffprobe's 864.50 s on the file.

`verify.py` — **all 8 checks ok**, including `A/B separation`:

```
07-tempo  src -1.90 -> film -1.70 LU (content +4.0 dB)
15-ab     src -5.30 -> film -5.20 LU (content +6.5 dB)
```

**Every card was looked at, not just the ones a frame pull happened to land
on.** I built a 2x6 contact sheet of `out/card00.png` .. `card11.png` and read
it: no overflow, no clipped row, no wrong string. The two most likely to have
been wrong were checked closely — card 4 carries the most list rows of any card
in this wave (8 chords) and fits, and card 8's unit line renders as
`DB, 250 HZ TO 1 KHZ`, which is the house all-caps unit style and reads
correctly. A faint mark above card 0's headline in the downscaled sheet turned
out to be a resampling artifact: the pixel band 60..180 of `card00.png` has a
max channel value of **18** against a background of ~13, i.e. nothing is drawn
there.

Content gate: best-matching stage **0.28** against a worst-matching control
**0.03** — a **9.0× separation** over 6 blind windows, with the omlx speech
server up on 8000 for the whole build (pid 28446, killed pid-exact afterwards;
`lsof -nP -iTCP:8000 -sTCP:LISTEN` empty after, with **17695 still listening as
the positive control that the probe works**). **Port 17600 was never listening
at any point in this session and was never contacted** — every command went to
17695 through `session/build.mjs`, which refuses 17600.

## THE FAULT THIS ONE HAD, AND WHAT I DID ABOUT IT

⛔ **This film does not have the audibility fault the first three had, and I did
not invent one.** The brief said so and the measurements agree: the prelude is a
mid-band instrument. Its energy peaks in the **250 Hz – 1 kHz** band at
**−27.76 dB** and it is **49.6 dB down below 100 Hz**. Any speaker reproduces it.

What IS said, because it is what the numbers show, is the honest consequence:
the two parts the film adds **underneath** Bach — the kick and the bass — are
exactly the two a laptop speaker reproduces worst. The band chart states this as
a measurement (`+57.82 dB` at 20–60 Hz, `+52.86` at 60–100) and the film ends
that chapter with a courtesy line about headphones, **not a gate** and not a
suggestion that the viewer's ears are at fault.

**Its weakness was explanatory**, like the Comma's. So the budget went on
pictures that are drawn from the note data and numbers that are measured.

### The centrepiece: the figure's invariance, tested with its own control

`anim_loops.py` `FigureInvariant`, **15.484 s**, stage `04-invariant` at 3:00 —
exactly the length of `piano124.wav`, which plays under it, so the bar
highlighted on screen is the bar you are hearing (each bar is 1.9355 s and the
scene steps one bar per bar).

The claim is structural and it is turned into a test a viewer can follow. For
each of bars 1–8, take the list of positions in the bar where a note starts.
Compare each bar with the one before. **The onset pattern changes 0 times out of
7.** Then run the *identical comparator* on a different property of the same
data — the set of pitches — and it **changes 7 times out of 7**, and finds that
**bars 1 and 4 are the only identical pair**. That second number is the positive
control: without it a zero could just mean the comparison was broken.

⭐ **Why this and not the other two candidates.** The brief offered three. The
piano-roll-with-the-pattern-highlighted is what `roll-figure.png` already is and
it is used in chapter 03; the bar-grid alignment is genuinely good and became
the *second* animation rather than the centrepiece. The invariance test won
because it is the only one of the three that is a **measurement with a control**
rather than an illustration — and because everything in it (144 notes, 16 onsets
per bar, 5 pitches per bar, the chord names) is read out of `bars1-8.json` at
render time, so nothing on screen can drift from the data.

I looked at frames 300 and 0 of the burst and at 200 s and 235 s of the finished
film. Two layout defects were found that way and fixed: the subtitle ran through
the "bar N" labels, and the five pitch names, right-aligned, grew off the right
edge so bar 6 photographed with four of its five notes.

### The other two animations

* `anim_loops.py` `NestedLoops`, **15.484 s**, stage `12-nested` at 9:50, under
  `ab-full-src.wav` (the finished track, bars 9–16). The same eight bars with
  four lanes underneath — the beat (0.484 s), the figure (0.968 s), the harmony
  (1.935 s) and the phrase (15.484 s) — revealed one at a time while a real-time
  playhead crosses. Every one of those four numbers is computed from the tempo,
  not typed.
* `anim_time.py` `BuildMarker`, **30.96 s**, stage `13-marker` at 10:39 — THE
  ATTENTION MARKER, under `full.wav` at real time. Four **measured** band
  envelopes of the render the viewer is hearing, one per layer, each shaded for
  one bar at the moment that layer arrives, with the step in dB underneath.
  ⭐ **The windows are derived** from the note data (each layer's own entry bar),
  and the step is measured in **that layer's own band at that layer's own hit
  positions** — see below for why that is not a detail.

## Measured numbers, and the commands that produced them

`MEASUREMENTS.json` is written by `measure.py` (ffmpeg EBU R128, Welch PSD,
spectral-flux onset-rate estimator, FFT band envelopes) over `audio/*.wav`, all
of which came out of `render.bounce` on staging 17695. `spec.py` carries **31
`check()` assertions** (counted: `grep -c '^check(' spec.py` -> 31, and `def
check` is the only other occurrence) that refuse to emit a spec if any spoken
figure has drifted from the measured one, plus four more build-time refusals: a
loop that checks each of the 8 chord names against the pitch-class content of
its bar, an `assert` on the eight bar roots, a guard that both halves of an A/B
are not the same clip, and a guard that every shot path exists.

### The material is Bach's, and it is checkable

`bars1-8.json` is bars 1–8 of BWV 846 parsed by `parse846.py` out of
`music21`'s corpus copy of `bach/bwv846.mxl` — a public MusicXML encoding of the
score (144 notes, 18 per bar). ⭐ **I derived the eight bars' pitch content
independently from memory first and then diffed**: the pitch classes matched bar
for bar; my octave was one out (I had the opening bass at C3, the encoding has
it at middle C, and the encoding's whole-piece range C2–A5 is the plausible
one). Recording that because "two recollections agree" is not a source.

### The invariance, and its control

| comparison, bars 1→8 | result |
|---|---|
| onsets per bar | **16**, in the same 16 places |
| **onset pattern changes** | **0 of 7 bar lines** |
| pitch-set changes (same comparator) | **7 of 7** ← the control |
| identical pitch-set pairs | **bars 1 and 4** |
| lowest note per bar (the bassline's source) | 60 60 59 60 60 60 59 59 — a C/B pedal |

### The tempo, measured off the audio rather than read off the field

| | predicted from the tempo | measured off the render |
|---|---|---|
| 72 BPM | 4.800 sixteenths/s | **4.800** |
| 124 BPM | 8.267 | **8.267** |
| ratio | 1.7222 | **1.7222** |

Eight bars take **26.67 s** at 72 and **15.48 s** at 124. `shoot.mjs` read all
**288** notes of the piano clip out of the app before and after
`transport.setTempo` and compared them as arrays: **identical** — same pitches,
starts, lengths, velocities, order. That comparison is a build-time assertion,
not a claim: `shoot.mjs` throws if it fails.

### What each part is worth — and the instrument that gets it wrong

Measured in each layer's **own band at its own hit positions**, the bar after it
arrives against the bar before, and the same four events measured on the
**whole mix**:

| part | enters | its own band | own-band step | whole-mix step |
|---|---|---|---|---|
| kick | bar 3 | 20–110 Hz | **+41.43 dB** | +6.00 dB |
| hats | bar 5 | 6–16 kHz | **+26.72 dB** | **−0.03 dB** |
| clap | bar 7 | 0.9–9 kHz | **+2.58 dB** | +0.15 dB |
| bass | bar 9 | 120–400 Hz | **+5.52 dB** | +1.37 dB |

⭐ **That contrast is a chapter, not a footnote, and finding it changed the
film.** The first version of the marker measured every layer on the whole mix
and got +6.00 / −0.03 / +0.15 / +1.37 dB — i.e. it said the hats and the clap
do not happen. They plainly do. The whole-mix level is simply the wrong
instrument for "a part arrived", and `chart-steps.png` now puts both numbers
side by side deliberately.

⚠ **The clap is the honest weak one.** +2.58 dB is small, and the film says why
(two events a bar, in a band the prelude already fills) rather than dressing it
up. I tried three bands for it (900–4000, 2500–9000, 900–9000 Hz) and a peak
measure as well as an RMS one; the hit-position measure in 900 Hz–9 kHz is the
largest honest number and it is still the smallest of the four.

### Where the house parts live (`chart-bands.png`)

Band energy of the finished track against the prelude alone, over the same eight
bars (Welch PSD):

| band | prelude alone | finished track | Δ |
|---|---|---|---|
| 20–60 Hz | −81.55 dB | −23.74 dB | **+57.82** |
| 60–100 Hz | −77.12 | −24.27 | **+52.86** |
| 100–250 Hz | −42.77 | −26.06 | +16.71 |
| **250 Hz–1 kHz** | **−27.76** | **−25.70** | **+2.06** ← Bach's own band |
| 1–4 kHz | −30.67 | −29.72 | +0.95 |
| 4–20 kHz | −46.09 | −35.58 | +10.51 |

That is the film's best single picture: the new parts went underneath and above
the thing that was already there, and left its own space almost untouched.

### Loudness

| render | ffmpeg EBU R128 | the app's own report | true peak |
|---|---|---|---|
| prelude alone, 8 bars at 124 | −21.0 LUFS | −21.03 | −10.1 dBTP |
| + kick | −17.6 | −17.60 | −3.3 |
| + hats | −17.3 | −17.25 | −3.3 |
| + clap | −16.9 | −16.94 | −1.1 |
| + bass (the finished track) | −15.7 | −15.72 | −1.0 |
| prelude alone at 72 | −22.9 | −22.93 | −10.5 |

Two instruments, agreeing to **≤0.05 LU on all nine files**.

### The A/B pairs

Both carry `normalize: false` and **ONE shared static gain** (peak-normalised by
the louder member of the pair), because `assemble.py`'s per-half loudnorm is
single-pass and dynamic:

```
tempo pair  ×2.2628   ab-t-a (72 BPM)  −15.8 LUFS   ab-t-b (124)  −13.9   Δ +1.90 LU
build pair  ×0.7907   ab-b-a (prelude) −23.1        ab-b-b (full) −17.8   Δ +5.30 LU
```

The build pair's 5.30 LU difference is **stated in the narration before the
comparison plays**, not normalised away.

### The demonstration survives assembly — checked on the DELIVERABLE

⭐ `verify_film.py` exists because `verify.py`'s A/B separation check compares
**loudness**, and neither of this film's demonstrations is a loudness
difference: `07-tempo` is a difference in RATE and `15-ab` is a difference in
SPECTRUM. It pulls each half back out of the finished mp4 at the position
`L5v2.mp4.timeline.json` records (trimming 1.0 s off each end to clear
assemble's fades) and re-runs the same estimators:

```
07-tempo  BEFORE  4.799 onsets/s   (source 4.800)
07-tempo  AFTER   8.266 onsets/s   (source 8.267)     ratio in the film 1.7224
15-ab     BEFORE  −75.14 dB below 100 Hz, −26.83 dB at 250 Hz-1 kHz
15-ab     AFTER   −19.98 dB below 100 Hz, −24.73 dB at 250 Hz-1 kHz
          → +55.16 dB at the bottom, +2.10 dB in the prelude's own band
```

Green, and written to `FILMCHECK.json`.

## ⛔⛔ A REAL PRODUCT DEFECT, FOUND WHILE BUILDING THIS

**The GeneralUser GS sound-bank path drops out on dense material, silently, and
a dropout renders as a perfectly valid wav.**

The 288-note piano clip was rendered three ways over the same eight bars, all
else equal. Per-bar RMS:

```
soundBank (GM piano), notes as written : -5.1 -27.4 -19.2 -69.1 -6.1 -10.0 -27.2 -19.1
soundBank, every note shortened 0.05 b : -5.7 -33.3 -63.0 -84.5 -6.5 -12.6 -53.5 -76.3
built-in polySynth, identical notes    : -15.8 -15.7 -15.8 -15.7 -15.7 -15.7 -15.7 -15.1
```

**Bars 1 and 4 hold the same five pitches**, so a 14–64 dB difference between
them cannot be the music. Shortening every note — which removes every same-pitch
abuttal, the documented note-off pairing hazard — made it **worse**, so that is
not the whole story. The built-in synth is even to 0.7 dB.

Two more facts from the same session, both worth filing:

* ⛔ **Once the transport has been run for a burst, every soundBank instrument in
  that app instance renders SILENT offline** — and the silent render returns
  `ok` with the loudness report simply ABSENT, not zero. The first take of
  `shoot.mjs` bounced eight files before the bursts (fine) and `piano72.wav`
  after them (digital silence, −70 LUFS). Re-issuing `track.setInstrument` did
  not revive it; the polySynth bass was unaffected. `shoot.mjs` now does every
  render before the first burst and asserts every bounce non-silent.
* ⚠ **`track.setVolume` is capped at 2.0 and CLAMPS SILENTLY.** The first
  balanced take asked the hats for 2.11 and got 2, so they rendered 3 dB under
  target and nothing said so. The balance is now set with a `gain` insert
  (+24.08 dB ceiling, clamps reported in `warnings`), and `shoot.mjs` throws on
  a warning.

**What this cost the film:** the prelude is played by the built-in poly synth
(a plucked saw: attack 0.003, decay 0.45, sustain 0.18, cutoff 3200 Hz), not a
sampled piano. That is an editorial loss and an honesty gain — the film says out
loud, twice, that this is a synthesiser playing Bach's notes and not a recording
of a piano, which is exactly true and is also the provenance line the brief
asked for. `measure.py` now **refuses to build** if any part's per-bar RMS
spreads by more than 6 dB; on the shipped renders the spreads are 0.93 dB
(piano, 8 bars) and 0.00–0.29 dB (the four solo probes).

## The material

* **The piano part is Bach's**, from the public encoding, unaltered in pitch and
  onset. It is 8 bars stated twice = **288 notes**, one clip, used at BOTH
  tempos — so "only the tempo changed" is true by construction rather than by
  intention.
* ⚠ **The note LENGTHS are the score's written durations.** A pianist's sustain
  pedal blurs those and the score does not encode it. The film says this out
  loud in chapter 03 and never claims the performance is Bach's — only the
  pitches and the note starts.
* **The bassline is his too**: each bar's bass note is the lowest pitch he wrote
  in that bar, moved down two octaves, on the offbeats. Bars 1–8 give C C B C C
  C B B — the pedal point.
* Kick / hats / clap are the GM drum kit (`bankMSB: 120`), which is sparse
  enough not to hit the dropout above and was checked bar by bar (spread 0.00 dB
  on all three).
* **No generation model was used for any of it**, per the standing rule.

## Build chain

```
python3 parse846.py                     # bwv846.mxl -> bars1-8.json (144 notes)
DAW_CONTROL_PORT=17695 DAW_TIMEOUT_MS=180000 SESSION_SHOTS=$PWD/shots \
  SESSION_BURSTS=$PWD/bursts node shoot.mjs      # project, balance, 9 renders,
                                                 # 7 stills, 5 app bursts
node    reburst.mjs                     # re-shoot the app bursts with the note
                                        # editor pointed at the prelude, plus the
                                        # 72 BPM burst chapter 02 needs
python3 measure.py                      # -> MEASUREMENTS.json, envelopes.npz,
                                        #    the four pre-gained A/B wavs
python3 charts.py                       # 4 measured charts into shots/
python3 bursts.py [invariant|nested|buildmark]   # 3 manim scenes -> bursts/ + beds
python3 spec.py                         # -> L5v2.json (12 cards, 17 stages, 2876 words)
../../shortsmith.py L5v2.json --out-dir out      # NO --finalize
python3 verify_film.py                  # the rate and the spectrum, off the mp4
node    restore.mjs <staging-before-bach.dawproj>
```

**Two honesty notes on that chain.** (1) `reburst.mjs` is NOT optional and is
NOT folded into `shoot.mjs`: running `shoot.mjs` alone reproduces the WRONG app
bursts — the note editor is still scrolled where the last still left it, so the
arrange bursts photograph an empty grid, and there is no 72 BPM burst at all. I
deliberately left it as a second step rather than merging the two: merging is a
five-line move, but I could only verify a merged `shoot.mjs` by re-running the
whole shoot against staging, which I had already restored, and unverified code
in the retained chain is worse than a documented two-step chain. Run both, in
that order. (2) `probe.mjs` is in this directory but is NOT part of the chain —
it is the diagnostic that solo-renders each part and is what found the
sound-bank dropout. It is kept for that reason only; nothing downstream reads
its output.

Everything heavy that is generated (`out/`, `bursts/`, `manim/`, `media/`,
`*.wav`, `shots/`) is covered by the `.gitignore` lines the mono-bass pilot
added. The retained chain (`*.mjs`, `*.py`, `L5v2.json`, `MEASUREMENTS.json`,
`bars1-8.json`, `renders.json`, `CHAPTERS.json`, `FILMCHECK.json`, `NOTES.md`)
is not ignored and is committable; `envelopes.npz` is regenerable by
`measure.py`. **I committed nothing.**

## What the old description said, and what mine measures

The shipped description is not quoted in the film and the film never refers to a
previous version of itself. But its claims were re-tested:

| its claim | mine |
|---|---|
| "128 notes went in and 128 came out" | **144** notes in bars 1–8; **288** in the 16-bar clip the film plays. 128 is 8 bars × 16 *onsets*, not notes — the bar has 18 notes in 16 onset slots, because the second-lowest pitch is struck twice under the top note. |
| "kick from bar 3, hats from bar 4, clap from bar 5" | **kick 3, hats 5, clap 7, bass 9** — my own staggering, over 16 bars |
| "The piano alone renders at −18.0 LUFS … the finished rebuild sits at −17.4 LUFS" | **−21.0** and **−15.7 LUFS** on my renders — different material, different balance; neither figure was copied |
| "tempo, from 72 to 124 BPM. That is all." | holds, and is now a build-time assertion on 288 notes rather than a statement |
| public domain, MIDI written for the video | holds, with the source named: `music21`'s corpus copy of `bach/bwv846.mxl` |

## Traps hit, in the order they bit

1. ⛔ **The sound-bank dropout** (above). It was found because the marker's
   per-entry steps came back as ±27 dB nonsense, which forced a look at the
   per-bar levels of the render itself. Four bars of every eight were 14–30 dB
   down **on identical note content**. A film built on those renders would have
   measured, charted and narrated a broken instrument as if it were music.
2. ⛔ **Every render after a burst is silence, and reports `ok`.** See above.
3. **`track.setVolume` clamps at 2.0 in silence.** See above.
4. **`fx.setParam` takes `name`, not `param`.** The MCP tool's spelling is
   `param`; the wire refuses it outright, which is the good failure.
5. **The whole-mix level cannot see a hats part arriving** (−0.03 dB). Measuring
   each layer in its own band at its own hit positions is what made chapter 13
   possible, and the wrong number is now carried on screen as the contrast.
6. ⛔ **A chart that was off screen when its own numbers were spoken.**
   `14-space` was `[card8, CH_BANDS, card9]` with `holdLast`, so
   `assemble.stills()` gave each of 7 slots 6.9 s and held only the LAST: the
   band chart was up 6.9–13.9 s while its figures are read from about ten
   seconds to forty. **Found by pulling the frame at 730 s out of the finished
   film and looking at it** — the speaker card was on screen under "fifty seven
   point eight decibels". Re-ordered to `[card8, card9, CH_BANDS]` with
   `cut=4.5`, and re-checked at 720, 735 and 750 s: the chart is up at all three.
7. ⛔ **A zoom crop whose right edge cut through the value it existed to show.**
   `TEMPO_124`'s first crop was `[0.14, 0.72, 0.28, 0.28]` — two thirds empty
   background, and its right edge landed at x=1344 of 3200, through the "124.0".
   Found in the film at 350 s. Now `[0.245, 0.805, 0.195, 0.195]`, checked
   against the PNG and then again in the film at 350, 381, 388 and 402 s.
8. **The A/B burst under chapter 02 was the wrong tempo.** `pianoplay` was shot
   at 124 BPM while `02-prelude` plays `piano72.wav`; the playhead would have
   been in the wrong place for thirteen seconds and no gate can see it. A
   `piano72play` burst was added; frame 1 reads TEMPO **72.0**, POSITION 1.1.
9. **The arrange bursts photographed an empty grid** in the bottom 40% of the
   frame, because the note editor was still scrolled to D6/G#5 from the last
   piano-roll still. Found by looking at frame 1. `reburst.mjs` now points the
   editor at the prelude clip, whole-clip zoom, centred on its median pitch.
10. ⛔ **`Text("")` has no points** and raises `too many indices for array` from
    `.move_to`. Both manim files use a middle dot in the background colour as an
    invisible placeholder instead.
11. **matplotlib bars drawn from zero on a negative dB axis** made the QUIETEST
    band the BIGGEST bar — the picture said the opposite of the numbers. Both
    bar charts now grow from an explicit floor. Found by looking at the png.
12. **Chart captions ran off the right edge; the longest y tick label was cut
    off at the left; two-line x tick labels ran into the caption; the legend sat
    on top of the bars.** All four found by looking, all four fixed with
    explicit margins.
13. **manim label clipping**, twice: the marker's one-line band labels ran off
    the LEFT edge and photographed as "K 20-110 Hz" / "00-16000 Hz" (frame 700);
    the invariance scene's subtitle ran through the "bar N" labels and its pitch
    readout grew off the RIGHT edge.
14. **The corner meter's footprint was computed, not guessed.** `meter.py`'s own
    `W_M/H_M/MARGIN` put it at x 1544–1884, y 996–1044 of 1920×1080 — manim
    units x 4.33–6.84, y −3.73 to −3.38. The marker scene's readout ran straight
    through that and was shortened and left-aligned. Checked in the deliverable
    at 690 s: clear. The bottom-right of all four charts is empty.
15. **Three content-gate refusals at build time**, which is the gate working:
    `00-open` had no literal "DAW Pro"; `12-nested` said "half bar" where the
    factCheck said "half a bar"; `15-ab` never said "normalised". And
    `13-marker` burned 8 takes because Whisper writes "minus 0.03" where the
    script spells the number out — every numeric factCheck now carries its digit
    twin.
16. **`set -- $var` does not word-split in fish**, so a loop of "start dur label"
    triples fed ffmpeg the whole string as `-ss`. Rewritten in Python.

## Judgment calls made while the user was asleep

* **Bars 1–8, not all 35.** Eight bars is the house phrase length, it is the
  passage everyone recognises, and it is the range I could verify against a
  source bar by bar. The film says "the first eight bars" every time it matters.
* **72 BPM is named as MY choice, out loud, in chapter 02.** BWV 846 has no
  tempo marking. Attributing 72 to Bach would have been the easiest false
  sentence in the film to write.
* **The piano is a synth, and the film says so** (see the defect above). I did
  not hide it behind "piano" and I did not go looking for another SoundFont —
  the dropout is in the path, not the patch, and a lesson has to be exactly the
  thing being taught.
* **Two animations, not one.** The grid picture was strong enough to keep but is
  not a measurement, so it became chapter 12 rather than the centrepiece.
* **The build A/B is not level-matched.** 5.30 LU is what four extra parts
  actually cost; the film states the number and the direction before it plays.
* ⛔ **The film never mentions that a previous version of it exists**, per the
  ruling recorded in the beethoven-128 notes.
* **No generation model** for any material, per the standing rule.
* **No screen recording.** `screenrec` was available and cleared, but every
  moving shot this film needs is the transport crossing a clip, which
  `debug.captureUI` bursts give at 1.9–2.6 fps with the framing the chapter
  wants (clip-scoped, centred on the notes' median pitch). The recorder captures
  the whole window and would have given smoother motion in a worse frame. Cost:
  the playhead steps rather than glides.

## What I could not do / known weaknesses

* **The app bursts run at 1.75–2.63 fps** (`meta.json` records the measured rate
  per burst), so the playhead moves in visible steps. First frames were checked
  on all six: `kickplay` reads POSITION 3.1 / TIME 0:03.870 (bar 3 at 124 BPM is
  3.871 s), `bassplay` 9.1 / 0:15.483 (bar 9 is 15.484 s), `piano72play` 1.1 /
  0:00.000 with TEMPO 72.0.
* **Card 9, the honest-listening card, is only on screen for 4.4 s**, because the
  band chart had to be held for the rest of the chapter (trap 6). Its content is
  spoken in full at the end of that chapter.
* **`verify.py`'s A/B separation is weak on the tempo pair** (1.90 LU — the two
  halves are nearly level-matched by design). The substantive protection there
  is `verify_film.py`'s onset-rate measurement off the deliverable.
* **The clap's measured step is small** (+2.58 dB) and I could not find an
  honest band or measure that makes it large. The film says why.
* **`transport-124.png` and `arrange.png` are the same capture** (identical UI
  state, taken back to back). Harmless — only the crops differ — but it means
  the transport shot is not independent evidence of anything the arrange shot
  is not.
* **The 04-invariant animation's audio is the prelude at 124 BPM**, while the
  chapter's argument is about bars 1–8 in the abstract. That is the right
  passage but it does mean the viewer hears the house tempo before chapter 07
  introduces it.
* **Spot transcription of the deliverable** (whisper-large-v3-turbo, same
  server): 200–218 s returns "…The onset pattern changes 0 times out of 7. The
  pitch set changes 7 times out of 7. That second number is the control…";
  560–578 s returns "…Measured in its own band, 120 to 400 hertz, it arrives
  5.52 decibels up."; 720–738 s returns the band figures. ⚠ That last window
  re-transcribed "2.06" as "2.03" **off the mixed film**; transcribing the clean
  VO wav directly returns "**2.06**" and "57.8", so the spoken word is right and
  the discrepancy is the recogniser working over a ducked music bed.
  **Negative controls**: 229–238 s and 795–807 s (music with no speech in them)
  both return "Thank you." — the documented babble artefact, i.e. the probe
  correctly finds no speech where there is none.
* **Per-take narration scores come from the build gate's own log**: 0.99, 0.99,
  0.99, 0.97, 1.00, 0.98, 0.99, 0.99, 0.99, 0.96, 0.96, 0.98, 1.00, 1.00, 0.95,
  0.97, 0.99 — all take 1 except `13-marker`, which took 8 before its factCheck
  was corrected and then passed on take 1.
* The staging session that was open before this work was saved to
  `…/scratchpad/staging-before-bach.dawproj` and **reopened and verified by
  re-reading**: tempo 100, tracks Pad / Bass / Drums / Lead (48 / 80 / 174 / 16
  notes, no inserts), playhead 0, master volume 1, `warnings: []`. ⭐ The panel
  layout was **read before anything was changed** and restored field for field,
  then re-read and diffed: no drift on any of the twelve fields
  (`pianoRollPPB 32, pianoRollRowHeight 14, rowHeight 50, editorFraction 0.45,
  editorMaximized false, followPlayhead false, pianoRollMinimap true,
  sidebarWidth 260, waveformNormalize true, waveformVerticalZoom 1,
  mixerInsertsCollapsed false, auditionEnabled true`). The mixer is closed.
