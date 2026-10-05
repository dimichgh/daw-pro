# Session film — "Four Waveforms"

**The claim:** every sound in this session comes from `saw`, `square`,
`triangle`, `sine` — the entire palette DAW Pro's poly synth offers. No sample
is loaded, no recording is used, no generation model is called. Verifiable,
because the whole session is driven over the control protocol and every number
is measured off the render.

**Why this is the right claim:** the synth genuinely has no noise oscillator
(`waveform must be one of saw|square|triangle|sine` — measured, with a bogus
control refused). That constraint is the film.

## Chapters

| # | Chapter | The "huh" | Status |
|---|---|---|---|
| 1 | Cold open — siren, heartbeat, thunder, a voice | none of it is a recording | material built |
| 2 | The instrument, and how it is being driven | the DAW itself was written by AI; every move here is a JSON command | — |
| 3 | The siren | one note. The pitch does everything. | ✅ 3.97 semitones measured vs 4.00 asked |
| 4 | The heartbeat | 94% of it is below 60 Hz — you feel it more than hear it | ✅ measured |
| 5 | Thunder | thunder is not a pitch, it is a filter closing | building |
| 6 | The 808 | the most famous bass in music is a sine somebody ruined | pending |
| 7 | **Rain — the one that failed** | measured 157× better and still 36× short | ✅ measured |
| 8 | A voice with no voice | two resonances are a vowel | pending |
| 9 | The effects tour | stock tools only | pending |
| 10 | DJ looping | layers built live | pending |
| 11 | Arrange | — | pending |
| 12 | Mix + master, measured | — | pending |
| 13 | The honest chapter | what I can and cannot judge | pending |

## Measured so far

- Waveforms available: `saw square triangle sine`; `noise` and `pulse` REFUSED.
- Siren: fundamental 393.4–494.8 Hz = **3.97 semitones** (the pitch-bend lane
  asks for 4.00); 8 wails in 8 s at 120 bpm, as written.
- Heartbeat: **94.0%** of energy below 60 Hz, 5.8% 60–120 Hz, 0.2% above 120 Hz.
  20 notes written (a 25 %-threshold detector finds 17 — the soft "dub" at
  velocity 88 sits under it; the number on screen must be the 20 that were
  WRITTEN, not the 17 a threshold happened to catch).
- Rain: spectral flatness **0.0001** (896 blips) → **0.0157** (3520 short
  grains). White noise measures **0.5615**; a single sine measures **0.0000**.
  So the mechanism is real and directional, and still 36× short.

## Rules carried from the lesson wave

- A non-musical demo sound must not bed under narration (`bedEligible: false`).
- Every figure on screen is measured, computed or cited.
- Nothing generated gets committed; tools and specs only.

## What shipped

Seven videos, all built from the one session and the one `MEASUREMENTS.json`.
The film and the Shorts quote the same figures because they read the same file
— a number is never typed twice, so the two can never disagree.

| File | Length | Argument |
|---|---|---|
| `DAW Pro Session - Four Waveforms.mp4` | 404.4 s | the whole build, start to finish |
| `DAW Pro Short 13 - One Note Siren.mp4` | 30.5 s | a siren is one held note; the bend does the moving |
| `DAW Pro Short 14 - Heartbeat Under 60Hz.mp4` | 28.9 s | 94 % below 60 Hz, so a phone plays none of it |
| `DAW Pro Short 15 - The 808 Is A Sine.mp4` | 44.7 s | drive adds above the fundamental, never below |
| `DAW Pro Short 16 - A Vowel Is Two Numbers.mp4` | 31.1 s | F1/F2 on a saw and it says *ah* |
| `DAW Pro Short 17 - I Failed To Make Rain.mp4` | 38.8 s | the chapter that did not work, with its numbers |
| `DAW Pro Short 18 - Thunder Is A Filter.mp4` | 33.1 s | a centroid collapsing, with the lane-off control |

⚠️ **The Shorts' content gate reports `[BROKEN]`, and that is the gate working.**
It refuses to score a transcript-vs-script separation on two stages under 45 s,
because with that little material the cross-stage control cannot mean anything.
A gate that declined to score is not a gate that passed — the Shorts' words are
covered instead by the per-stage `factCheck` assertions, which all passed.

## The zoom bug, and why every gate missed it

The film shipped once with `04-siren`'s zoom framing **empty timeline** below the
synth panel. All eight verify gates passed: `distinct frames` is perfectly happy
with two different views of nothing, and no gate in this rig has any idea *where*
a crop lands. The same pass found the saturator panel reading `30.0 dB` while the
narration says "thirty two decibels" — the figure the sweep was actually measured
at, so the panel was re-shot rather than the sentence re-worded.

**The check that found both takes three minutes** and belongs in every session:
render each `zoom` rect as a still and look at it.

```sh
ffmpeg -y -i shots/<name>.png \
  -vf "crop=iw*<w>:ih*<h>:iw*<x>:ih*<y>,scale=860:-1" -frames:v 1 /tmp/check.png
```

## And three card bugs under it

The same frame that exposed the zoom showed the card behind it reading **"E
SIREN, MEASUR"**. Three separate faults, none of which any gate can see:

1. `sp()` joined letters with three literal spaces while the renderer *also*
   letter-spaces with `track=`. Every label was three times its intended width,
   so the auto-fit shrank it to 12–24 pt. Legible, and clearly wrong.
2. `card_bignumber` had no fit on `label` or `unit` at all — `card_list`'s title
   had been fixed for exactly this and the big-number card had not — so a label
   that overflowed was simply sliced at both ends.
3. A `list` card's left key had no column bound and drew through its own value.

Fixed in the renderer, so the next spec cannot hit them; and the spec's own keys
were shortened so nothing has to shrink in the first place.

## And a fifth one, from the same instrument

Looking again at the 808 chapter's A/B — the film's centrepiece — found the
"before" half showing the **saturator panel at 32.0 dB** while the narration
says *"here is a clean sine"*. Exactly the contradiction the 30-vs-32 re-shoot
had just fixed, one row down in the same `dict`, and every gate passed it twice:
a gate can read the script and it can read the panel, but nothing in this rig
compares the two.

Fixed by shooting the 808's own **POLY SYNTH on 808 sub** panel with SINE lit
(`synth-808-sine.png`) and pointing `beforeShots` at it.

Two things that made the re-shoot cheap and safe:

- The app's `DAWPRO_PROFILE_ROOT` env var moves the whole profile (autosave,
  recovery, settings) to a scratch directory. The first attempt came back with a
  **"Restore unsaved work?" sheet drawn straight across the panel** — the only
  clean way past it, `project.recover {accept:false}`, discards a recovery
  snapshot whose owner cannot be told apart from the user's, so it was never an
  option. An isolated profile root has no snapshot to offer.
- Build the shot in a **fresh project**, never by reopening the session file:
  `project.open` on the 8-track project wedged the app twice.

## The one that fixing a bug created

Re-shipping the film after the A/B fix produced a file **eleven seconds
shorter**, with all eight gates green. Nothing in the build said why.

`shortsmith.py` names each narration take after its **stage id** — `vo/01-hook.wav`.
The film and its six Shorts had been built into one `--out-dir`, and the film
has a stage called `01-hook`; so does Short V1. The Shorts were built second, so
V1's fourteen-word opening was sitting at that filename. `--skip-narrate` reuses
whatever take is on disk without looking, so the rebuild assembled **the Short's
opening line into the film**, under fifty-one words of script.

Every gate passed it. Every gate measures the file that exists — streams, drift,
loudness, distinct frames — and the content gate compares the audio to the
script it was *handed*, not to the script that stage was written from. A wrong
take is a perfectly healthy file.

Two fixes:

- `--skip-narrate` now **verifies the cache before assembling** and refuses,
  naming the offending stages, when a take on disk was recorded from different
  text or gates (`verify_cached()`). It skips synthesis, which is what it was
  for; it no longer skips knowing whose voice it is using.
- Give each spec its **own `--out-dir`**. Shared ids across specs is not an
  unusual shape — every one of these Shorts opens with `01-…`.

The way it was caught is the reusable part: **the eleven seconds were the only
symptom**, and the way to read them was words-per-minute per stage. Eleven of
twelve stages sat between 226 and 266 wpm. `01-hook` read **831**.


## The second cut, and what a viewer actually noticed

The film shipped, the user watched it, and every note back was about something
no gate in this rig can measure. Worth recording verbatim, because they are all
the same class:

1. **"talking about heart beat and then switching to thunder without saying
   something prolog or visual title"** — chapters cut into each other with no
   break at all. Fixed: ten numbered title cards, each with a spoken prolog.
2. **"showing controls does not make sense unless you show modifying anything
   there"** — dead right. A still of a synth panel cannot be told apart from a
   panel that is doing something. Every panel in the film is now a SEQUENCE of
   stills of the same crop with the value stepping: four waveform buttons
   lighting in turn, the thunder filter closing 16 kHz → 70, the saturator at
   0 / 14 / 32 dB, the two EQ peaks walking ee → ah → oo.
3. **"the most recognizable base in modern sound music… again no intro of what
   it means"** — the film used the word "808" for four minutes without ever
   saying what one is. Fixed in that chapter's prolog.
4. **"for playing some of the very low volume sounds, you may need to warn
   watcher to increase the volume"** — the heartbeat is 94 % below 60 Hz and a
   laptop plays none of it. There is now a TURN IT UP card and a spoken warning
   before it.
5. **"you need to show that you did the work in DAW, not just saying it"** —
   the reason for all of the above.

## What the app can and cannot be filmed doing

- **`debug.captureUI` runs at 3.5 frames per second, and it is the same 3.5 at
  every capture `scale`** (measured: 277 / 282 / 284 ms per frame at scale 2 /
  1.5 / 1). The cost is the window render, not the pixels — so shrinking the
  image buys nothing. That is the ceiling on motion in these films.
- **Screen recording is not the way around it.** It needs a TCC permission this
  process cannot grant itself, the staging window is not on screen at all
  (`CGWindowList` lists no window for the process — the capture path renders the
  window's layer directly), and it would record the user's whole desktop.
- ⭐ **`debug.selectClip` DOES NOT EXIST, but the capability does** — as a
  PARAMETER of `debug.captureUI` (`{selectClip: <clipId>}`). The film went out
  once without a single shot of the piano roll because `capture.mjs` called a
  command name that never existed, and the wrapper printed "skipped" into a log
  nobody read. Verified with the `DAW_DEBUG_OPEN_PIANOROLL` dev flag OFF.
- ⭐ **`DAWPRO_PROFILE_ROOT` is the shot-taking flag that matters**: it moves
  autosave/recovery/settings to a scratch directory, so no "Restore unsaved
  work?" sheet can draw itself across the panel being photographed.

## "Hi there", and what a speech recogniser heard

The vowel chapter proves a vowel is two numbers. The words chapter asks the
obvious next question: a word should then be those two numbers MOVING. So the
two EQ peaks were put on automation lanes and walked along a vowel path —
ah → ee for "Hi", eh → er for "there" — over two held saw notes.

Measured, in 100 ms windows, as dB above the window's own mean level: 730 Hz
leads at the start (**+29.1**), 2290 Hz takes over through the glide
(**+19.0** at 0.90 s), 1840 Hz leads the second word (**+26.6** at 1.40 s). The
path moved.

Then the only honest test available: feed it to the same local speech
recogniser that gates this narration. **It heard "I am…"** — with a control
transcription of a known-good take proving the recogniser was working.

That is the right answer for the wrong-sounding reason, and it is why the
chapter is in the film. The vowels landed. Every consonant did not: /h/, /ð/
and /r/ are noise, and noise is the one thing this instrument cannot make.


## "Is the 808 deliberately quiet?" — no, and gain cannot fix it

The viewer asked whether the 808 and heartbeat chapters were intentionally low,
and whether to warn people or just raise the level. Measured, as the segments
actually sit in the film:

| segment | integrated | true peak | RMS |
|---|---|---|---|
| heartbeat | −15.7 LUFS | **−1.5 dBTP** | −15.7 dBFS |
| 808, saturated | −16.4 LUFS | −6.1 dBTP | −14.6 dBFS |
| siren | −16.2 LUFS | −10.3 dBTP | −20.4 dBFS |
| full track | −16.4 LUFS | −3.8 dBTP | −17.9 dBFS |

**They are already the loudest things in the film**, not the quietest —
`assemble.py` loudness-normalises every demo (`loudnorm=I=-16:TP=-1.5`), and the
heartbeat sits exactly on the true-peak ceiling with no headroom left. Raising
it further would clip, not help.

The missing thing is the BAND, not the gain. Through two cascaded 150 Hz
high-passes — roughly what a laptop speaker does to you for free:

| segment | energy lost |
|---|---|
| 808, clean | **−38.2 dB** |
| 808, saturated | −33.6 dB |
| heartbeat | −30.2 dB |
| full track | −3.7 dB |
| siren | −0.1 dB |

⭐ **The 4.6 dB between the two 808 halves is the chapter's own thesis, and it
had never been measured.** The film claimed saturation makes the note carry on a
small speaker; now it quotes the number, and the A/B is stated to be
loudness-matched so nobody can read it as a volume trick.

So the answer was neither "warn" nor "raise" alone: **raise is impossible, and
the warning got better by being a measurement.** The 808 chapter now carries the
TURN IT UP card too — it was four minutes after the only other one — and the
card says what it costs you rather than just asking.


## The third cut: the playhead actually moves

The remaining note was the sharpest one: *"as you play sounds, can you show DAW
transport and note editor as playhead travels through them"*. Until now a demo
segment was a **frozen picture with audio over it** — the least honest frame in
a film whose whole claim is that the work happens in the app.

`assemble.py` already had the mechanism and nothing used it: a stage can name a
**burst**, a directory of frames plus a `meta.json` giving their frame rate, and
the play segment is built from those instead of a still. What was missing was
anything that produced one.

`build.mjs` now exports `burst(name, seconds, fromBeat, opts)`. It opens the
piano roll on the clip, starts the transport, and photographs the app until the
sound is over. Nine of them exist: siren, heart, thunder2, bass808,
bass808-clean, vowel, hithere, track-drop, dj-build.

⭐ **Real time comes for free.** `debug.captureUI` costs ~285 ms per frame, so
the transport advances ~285 ms between frames; a sequence played back at the
**measured** capture rate is the playback, correctly paced. Measured rates were
2.2–2.9 fps with audio running (against 3.5 idle), and `meta.json` records what
actually happened rather than assuming a number.

Three things this cost, each worth keeping:

- ⚠ **Master volume to zero before playing.** This plays through whatever output
  device the machine has, and nobody asked for eight seconds of siren out of
  their speakers. The audio was already rendered offline; the burst wants only
  pictures.
- ⚠ **A whole arrangement is the wrong thing to show in a piano roll.** The
  first `track-drop` burst opened the Kick clip's roll, scrolled to bar 1 while
  the playhead was at bar 36 — an empty grid, photographed 36 times. The
  multi-track chapters use `{arrange: true}`, which shows the arrangement with
  follow-playhead on. Caught by looking at one frame.
- ⚠ **These scripts did not exit.** `close()` does not always let node's event
  loop drain, so a finished script looked exactly like a hung one and blocked
  the capture loop for four minutes per chapter. They now `process.exit(0)`.

And a gate for the new failure mode: a stage naming a burst directory that does
not exist **silently degrades to a frozen still** — the exact thing this change
removes. `shortsmith.py` now prints a warning naming the stage and the missing
path at build time. The rain chapter is the one stage that keeps a still, and
says why in the spec: its two attempts were built by an ad-hoc script that is
not in this directory, so there is no builder to photograph.

## The fourth cut — the roll finds its notes, and a meter in the corner

Two of the previous cut's bursts were photographing an empty grid, and the grid
was not lying. A heartbeat lives at C1, a 49 Hz sine; the piano roll opens
anchored high in the 128-row pitch stack, so those notes were drawn in the
minimap and in the velocity lane and nowhere the camera was pointed.

The obvious lever was zoom, and it does not work. **Measured at the 10 pt
row-height floor — the clamp, which is where a request for 5 lands — the grid
still bottomed out at F2**, with the notes below it —
shrinking rows fits more keys and keeps the same anchor. So the pitch axis got a
way to be *pointed*: `debug.panelLayout {pianoRollCenterPitch}`, and `burst()`
sends the clip's own **median** pitch, which is right for every chapter and
special-cases none of them.

⚠ Two orderings matter and neither is guessable: the roll has to be OPEN before
the request lands (the scroller must exist for it to scroll), and the focus has
to come AFTER any row-height change (a row-height change re-pins the axis and
would quietly undo it).

The other half of the cut is a small live spectrum meter in the bottom-right,
in the intro sting's palette. A narrated film is mostly static frames and a
viewer has no way to tell "this is playing" from "this is paused" except by
listening. It is a real 16-band analysis of the film's own audio, not a wiggle:
**at the heartbeat, bands 0–6 stand at full height and 7–15 at zero** — which is
the whole thesis of that chapter, drawn in the corner while it plays.

Three things it cost:

- ⚠ **One global dB scale killed the top half of the meter.** A magnitude
  spectrum falls steeply with frequency, so scaled together every bar above
  600 Hz pinned to zero for the whole film — eight dead bars that looked like a
  design choice. Each band is now scaled against its own loud end, and the whole
  display is gated by how loud the frame actually is, so silence stays silence.
- ⚠ **It shipped an 872 ms a/v drift on its first run.** The meter is generated
  from the AUDIO, which in an assembled film runs slightly longer than the
  video; `overlay=…:shortest=0` makes the output as long as the LONGER input, so
  the overlay extended the video by the difference and nothing else. The gate
  caught it, which is why the meter runs BEFORE the gates and not after them.
- ⭐ **Two instruments disagreed and neither was broken.** The meter read flat
  where `ffmpeg astats` read −16 dB. `ffmpeg -ss` placed before `-i` is a FAST
  seek and does not land on the second you asked for: they were reading
  different moments, and the audio at that instant really is a −37 dB gap
  between words. Check that two instruments are pointed at the same sample
  before believing either.
