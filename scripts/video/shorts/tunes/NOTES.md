# Six wordless music Shorts — `scripts/video/shorts/tunes/`

Nine-by-sixteen, no narration, music and a bar. Built 2026-09-06 against
**staging 17695 only**; port 17600 (the user's live app) was not running for the
whole session and was never contacted.

| dir | film | duration | integrated | true peak | size | tracks | notes | key / tempo |
|---|---|---|---|---|---|---|---|---|
| `01-stack` | `out/stack.mp4` | 51.90 s | −13.9 LUFS | −1.0 dBTP | 10.1 MB | 12 | 809 | A minor, 128 |
| `02-rooms` | `out/rooms.mp4` | 53.43 s | −14.0 LUFS | −1.0 dBTP | 7.6 MB | 20 | 570 | A minor (Am F C G), 100 |
| `03-colours` | `out/colours.mp4` | 54.37 s | −13.9 LUFS | −1.2 dBTP | 7.1 MB | 14 | 508 | D major, 126 |
| `04-canon` | `out/canon.mp4` | 49.10 s | −13.9 LUFS | −1.1 dBTP | 7.2 MB | 5 | 471 | E major pentatonic, 116 |
| `05-accel` | `out/accel.mp4` | 42.30 s | −14.2 LUFS | −1.1 dBTP | 7.1 MB | 5 | 566 | E minor, 60→180 |
| `06-cascade` | `out/cascade.mp4` | 49.07 s | −14.3 LUFS | −1.1 dBTP | 7.6 MB | 26 | 468 | D major pentatonic, 132 |

Loudness figures are ffmpeg `ebur128` on the **finished mp4**, after the AAC
encode and with the outro included. The mix each was steered to, measured by the
DAW's own `render.measureLoudness`, is in each `out/loudness.json` and reads
−13.75 to −13.92 LUFS.

Every instrument is **MuseScore General** (`~/Library/Application
Support/DAWPro/SoundBanks/MuseScore_General.sf2`, 205.6 MB) through the
`soundBank` instrument path. The staging app runs with `DAWPRO_PROFILE_ROOT`
pointed at `scripts/video/lessons/out/profile`, so its bank library is that
profile's `DAWPro/SoundBanks` and MuseScore was **not** in
`instrument.listSoundBanks` until a symlink was added there. Nothing else in the
user's library was touched. **That symlink is DELIBERATELY LEFT IN
PLACE**: it lives in the repo's own staging build-output profile
(`scripts/video/lessons/out/profile/DAWPro/SoundBanks/`), not in the user's
library, it only points AT the user's file and never writes to it, and removing
it would break re-running this chain. Nothing was added to, moved in or removed
from `~/Library/Application Support/DAWPro/`.

## ⛔ The app window CANNOT be a 9:16 frame — measured, twice

`debug.windowFrame {width: 540, height: 960}` answered **`{width: 1208, height:
960}`**: `WindowFloor.minWidth` is 1208 pt and the request was clamped, not
refused. Asking for 1208×1200 on this display answered **1208×1013** — the
screen's own ceiling. So the tallest, narrowest main window that exists here is
**1.19 : 1, i.e. landscape**, against 9:16's 0.5625. Downscaled to 1080 wide it
fills 906 of 1920 px and leaves more than half the frame empty; cropping a
column out of the middle is the measured-ugly option this tree already rejected.
`_evidence/app-portrait-attempt.png` is that window, editor maximised, piano
roll pointed at the notes — 2416×2026 px of it.

So the picture is **`lib/viz.py`**: a purpose-built vertical piano roll in the
app's own idiom — dark glass, black-key columns running the full height, a
moving beat/bar grid, neon notes with additive halos, and a bar they cross and
light up on. Not a rhythm-game highway. `scripts/video/meter.py`'s corner
spectrum meter is burned in bottom-right, driven by the film's own audio.

## The chain

    song.py  ->  song.json  ->  lib/build.mjs  (staging 17695: tracks, sound-bank
                    |            instruments, sends, reverb bus, master gain+limiter,
                    |            render.mixdown)  ->  out/music.wav
                    |         lib/gain.mjs      (steer the master gain insert to
                    |                            -14 LUFS, re-render, write the
                    |                            converged gain BACK into song.json)
                    +------->  lib/viz.py -> rawvideo -> ffmpeg -> picture.mp4
                               lib/tunesmith.py: mux, brand outro, true-peak
                               backstop, meter.py, verify.py, lib/sync.py

`song.json` is the ONE contract: the sound and the picture are generated from
the same numbers by two independent paths, and `lib/sync.py` is what proves they
agreed.

**No brand intro, deliberately** — a departure from every other short in this
tree. The brief is "catchy in two seconds"; four seconds of title card is the
two seconds and then some. The brand lands on a 2.4 s outro.

**shortsmith.py is bypassed**, for two reasons that are not stylistic:
`verify_cached` refuses to assemble without a narration take per stage, and
`assemble.py`'s play beat runs `loudnorm=I=-16` over the music, which would undo
the −14 the mix was steered to. Every gate shortsmith runs is run here.

## Gates, each with the control that makes it mean something

| gate | result | control |
|---|---|---|
| `verify.py` streams / frame size / A-V drift / distinct frames / audio present / loudness / joins | 7 ok on all six | its own, incl. frame-vs-itself = 0.00 for distinct frames |
| `verify.py` content | **BROKEN, "not applicable: 0 narrated stages"** — the one allowlisted broken probe. A wordless film has no words. | — |
| `lib/sync.py` | ok on all six, 57–96 % of detected onsets within 35 ms | wrong-phase (half-gap) expectation scores 3.8–27 %; **and the whole gate FAILS when the cascade's film is scored against the canon's song.json (24.9 % vs a 25.8 % control)** |
| `lib/sync.py` drift | 0.6–4.8 ms across the piece | one video frame is 33.3 ms |
| `lib/identity.py` (Twelve Colours) | all 12 phrases hash to `2786959d871bfecc` | **`--mutate 5` moves one note by a semitone and the check FAILS: "2 distinct phrases across 12 tracks"** |
| stem levels (`lib/stemlevels.sh`) | every one of 26 + 20 + 12 stems carries signal | a file of digital silence reads `-inf` |
| frames read, not just pulled | 12 frames opened and looked at | `md5 -q | sort | uniq -d` over the batch returns nothing |

### The systematic +15 to +19 ms — I had this WRONG, and measured it

Every film reports a median onset offset of +14.5 to +19.0 ms, constant across
the thirds of every piece **including the accelerando**, whose clock more than
triples. I wrote here that the constancy proved it was the onset detector's own
latency (a flux peak landing after the true onset). Constancy proves it is not
*drift*; it does not say where the offset comes from, and the direction I
asserted is the opposite of the truth.

**Measured** (`lib/sync.py`'s own `onsets()` run on a synthetic file of 40
1 kHz clicks at exactly known times, 22.05 kHz, same code path):

    detected 40 of 40 known clicks
    median bias -16.6 ms, spread 10.9 ms

The detector reports onsets **16.6 ms EARLY**, not late. So the films' +16 ms is
not detector lag masking a perfect render — correcting for the bias, the
rendered audio's onsets sit about **+32 ms after** the score times the picture
is drawn from, i.e. the sound trails the picture by roughly one video frame.

What I can say about the cause: it is constant across tempi, so it is a fixed
pipeline offset, not a clock error. Candidates I did **not** separate are the
master limiter's lookahead and the SoundFont attack envelopes (a bowed or
plucked sample's energy peak arrives after its note-on, and the click test used
an instant attack, so the detector's bias on real material is not the -16.6 ms
it shows on clicks). Both would be flat across tempo. I am not claiming which.

It is under one video frame either way, `verify.py`'s independent A/V drift
check reads 4.7-31.3 ms on all six, and no gate is affected. But the earlier
sentence here read like a measurement and was an inference with the sign
backwards.

### Why the "reversed" and "random" controls were replaced / demoted

Time-reversal is **not** a control for metrical music: reversing onsets that sit
on a regular grid gives back the same grid, and it scored 84.1 % against an
85.7 % real match on the canon. It was replaced by a random set of the same
density. That one in turn **saturates** on dense material — a random time has
chance `1 − exp(−2·tol·density)` of landing near some onset, which is 46 % for
the cascade's sixteenths, and it measured exactly 46.0 %. So the verdict reads
the half-gap **phase shift**, the adversary with the same density and the wrong
phase; the random figure is still printed next to its analytic expectation.

## Defects found by looking, after everything passed

1. **`render.mixdown` wrote 17.9 MB to `<repo>/out/music.wav`.** `lib/gain.mjs`
   passed the out-dir through verbatim and the APP resolved the relative path
   against its own cwd, answering `ok` with a real wav at a plausible name. The
   film downstream then used the STALE file beside the song, so the first canon
   build shipped **5.1 dB louder** than the mix the script had just converged,
   and every printed number said −13.9. Caught because ffmpeg and the DAW
   disagreed by 5 dB on the same file — a calibrated 1 kHz tone proved the two
   meters agree to 0.0 dB, so the disagreement had to be two different files.
   Fixed by resolving the path and asserting `r.path === want`. Stray file
   deleted.
2. **The true-peak backstop oscillated**: −0.80 dBTP, trim −0.20, → −0.90, trim
   −0.10, → −0.70. Turning the audio down made the measured peak go up, because
   each pass was a fresh lossy AAC encode of an already-lossy one. It now
   re-encodes from the original PCM at a cumulative trim and converges in one
   pass.
3. **A beat line drew straight through "Bowed glass pad"** — the header was
   baked into the static layer, under the notes. Now drawn per frame, last,
   over a scrim that outlasts the legend.
4. **The Stack's twelve-row legend ran to y=674**, far below the scrim, six
   names unreadable on top of the falling notes. Two columns past seven rows.
5. **The cascade's subtitle was cut off at the right edge** — a valid PNG with
   the sentence sliced. The subtitle now shrinks to fit.
6. **Twelve Colours' current-instrument label read "Kit"** while a vibraphone
   played the line the entire short exists to show: the hi-hat is always the
   most recent onset. Backing parts now carry `legendIgnore`.
7. **Four parts were 17–24 dB under their own room** (see
   `MEASUREMENTS-stems.txt`): the bossa brush kit at −49.6 against a −25.6
   nylon guitar, the lo-fi brush kit, the lo-fi vibraphone, the house synth
   bass. And The Stack's sub bass read −46.5 in the tutti. All found by
   measuring each stem **in its own window** — over the whole file a part that
   plays for one room of five reads ~7 dB low and looks buried when it is merely
   brief. Fixes are in the `song.py` files with the measurement that forced
   them; the Stack's bass took three measurements to land (program 38 was too
   quiet, program 33 with a +6.8 dB insert was the loudest thing in the mix by
   nine, program 33 trimmed to 0.62 sits at −27.4).

8. **All six shipped an outro card reading "Narration is a synthetic voice. No
   music-generation model was used." — on films with NO narration at all.** The
   shared brand card is written for the narrated series and every gate here is
   deaf and blind to words on a card; I found it by pulling a frame at 48.2 s
   out of the FINISHED canon and actually opening it. The shared
   `claude-plugin/skills/demo-film/brand.json` is UNTOUCHED (every other film
   reads it); `lib/brand.tunes.json` is a local copy whose sub-brand reads
   `T U N E S` and whose two lines now read "Every note written by hand, in DAW
   Pro" / "No narration. No music-generation model: the app's own sound bank
   plays it." `lib/reoutro.py` re-made the outro on all six from each film's
   existing `body.mp4` (which already carries the converged true-peak trim),
   re-applied the corner meter and **re-ran both gates**; the new card was then
   read off a finished frame of the cascade. Measured after: durations and
   loudness unchanged to the digit, sizes moved by 1–2 KB.
   ⚠ Still there and left alone: the corner meter draws its (empty, silent)
   frame over the outro card's bottom-right. It is small and correct — the
   outro IS silent — but it is a thing the film shows that nobody asked for.
9. **`05-accel/out/tempo-echo.json` was written and never compared.** Now it is:
   all **65** segments echoed by the engine are identical to `song.json`'s to
   4 decimal places, first `(0.0, 60.0)` and last `(64.0, 180.0)`; a positive
   control that perturbs one bpm by +0.001 makes the comparison return False.
   So "the engine played the map I drew" is a read fact, not an inference.
10. **The onset detector's bias, above, was asserted with the sign backwards.**
   See "The systematic +15 to +19 ms".

11. **The Stack opened on two seconds a phone cannot reproduce.** Measured on
   the shipped file: **83.9 %** of the first two seconds' energy below 120 Hz
   and only **1.9 %** above 300 Hz (controls: a 60 Hz sine reads 0.000 % above
   300 Hz, a 2 kHz sine reads 100.000 %). The concept says "kick alone" and the
   brief says "enjoyable in the first two seconds"; those two disagreed, and the
   brief wins. **Changed:** the closed hi-hat now enters WITH the kick as one
   drum kit (still one instrument, so the two-bar ladder is intact) and the old
   bar-4 hi-hat entry became a snare-and-shaker layer. Re-measured after:
   **14.8 %** above 300 Hz, 72.3 % below 120 — 7.8x more of the opening in the
   band a phone actually reproduces. The short was rebuilt end to end: 809 notes
   (was 667), 51.90 s, **−13.9 LUFS / −1.0 dBTP**, LRA 5.8 LU, sync **95.8 %**
   against a 4.7 % wrong-phase control, drift 1.6 ms, verify 7 ok. Legend rows
   now read "Drum kit" and "Snare + shaker"; read off a finished frame at 40 s.

## Housekeeping

- Staging's project was saved to `_staging-backup.dawproj` before the first
  `project.new` and reopened at the end; `project.overview` after the reopen
  reads **2 tracks / 216 BPM / "Strings, Click"**, field-for-field the record in
  `_staging-before.json`.
- ⚠ The window frame was resized **before** it was read, so its original size is
  unknown and was not restored to it; it was set to 1600×1000 and the panel
  layout to the ui-capture defaults (`pianoRollPPB` 55, `pianoRollRowHeight` 14,
  `editorFraction` 0.43, `editorMaximized` false, follow-playhead off, mixer
  hidden, transport at 0). That is the one restore that is approximate, and it
  is stated rather than glossed.
- `out/stems/` was deleted after measuring (1.1 GB); `lib/stems.mjs` regenerates
  it. `out/seg/` holds meter.py's intermediates and `out/<id>-nometer.mp4` is
  the pre-meter master, kept so the meter can be restyled without a rebuild.
- Nothing was committed or staged. `--finalize` was not run and nothing was
  uploaded.
