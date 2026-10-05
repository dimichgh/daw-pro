# Rebuilding lessons 4–11 to the house standard

**Scope, decided by the user 2026-09-05: the eight films published as Lesson 4
through Lesson 11.** (Internally these were L1–L8; published Lesson 8, "Mono
Your Bass", is inside this set.) Lessons 1–3 are an earlier wave and are out of
scope for now.

## Why they are being rebuilt, and what "rebuilt" means

The user watched the compressor lesson's second cut and adopted its format:

> *"this is super good version, the style, the format is good, let's use it for
> existing that needs to be re-generated and similar for future videos, so move
> it. The time is not a hard constraint, the quality is what should define how
> much time we need for learning."*

⚠️ **Nothing survives from these builds except the finished mp4 and its
`.publish.json`.** No manifest, no narration script, no shot set, no source
wavs. There is nothing to patch — each film is written and shot again.

⭐ **What DOES survive is worth reading first:** each `~/Movies/<name>.publish.json`
carries the title, tags and a long description that usually states the film's
setup and its measured numbers. `docs/lessons/PROGRAM.md`'s wave-3 table carries
the headline measurements. Between them the ARGUMENT of each episode is
recoverable — but ⚠️ **every number must be re-measured off the new render, not
copied from the description.** A number that survived a doc round-trip is not a
measurement.

## ⭐⭐ The user's directive for this wave, 2026-09-05

> *"re-do with focus on explainability and quality, not fixed time, use all your
> nice tools and screen captures to make it better and intro and whatever you did
> in last excellent video"*

Read that as four instructions, all binding:

1. **EXPLAINABILITY IS THE PRIMARY GOAL.** If a chapter is correct but a novice
   would not follow it, it is not done. Correctness is the floor, not the target.
2. **THERE IS NO TIME BUDGET.** Do not trim an explanation to hit a length. A
   rebuilt lesson running twice its original length is a success if the extra
   time is spent explaining.
3. **USE THE FULL VISUAL TOOLSET, GENEROUSLY.** manim for anything with a
   mechanism or a curve; matplotlib for anything with a set of measurements;
   `debug.captureUI` for the app doing the actual work. ⚠️ **A static frame with
   a voice over it is the thing this wave exists to replace.** Where the old film
   asserted something over a still, build the picture.
4. **CARRY OVER EVERYTHING FROM THE COMPRESSOR RE-CUT** — the novice chapter 0,
   the measured charts, the real-time playhead with derived listen-windows, the
   honest treatment of anything inaudible.

⚠️ **`debug.captureUI` remains the capture method** (headless, no window needed —
the user named it as a feature they like). The ScreenCaptureKit recorder is
approved but NOT BUILT, and is for motion only.

## Screen recording is available from 2026-09-05 — with ONE hard rule

The user cleared its use for this wave ("I am going to bed and I will keep this
laptop working, so in case you want to record screen, there is nothing blocks
you"). `scripts/video/screenrec/` is built, the permission is granted, and it
records real motion (150 frames in 5.0 s at 30 fps, proven against a static
control). Use it for **motion only** — a control being dragged, a playhead
sweeping, a meter moving. `debug.captureUI` stays the default for stills.

⛔⛔ **RECORD THE `DAWApp` WINDOW AND NOTHING ELSE. EVER.**

`--list` on this machine returns **109 capturable windows**, including the
user's browser, their editors with open source files, and a dozen terminals
holding other projects' sessions. A full-screen or wrong-window capture puts the
user's private content into a video file, and this wave runs unattended while
they are asleep and cannot catch it.

- Always target explicitly: `--app DAWApp` (optionally plus `--window-title`).
- **NEVER** record the desktop, the menu bar, the Dock, a browser, an editor or
  a Terminal — not even "briefly to check it works".
- **LOOK AT THE FIRST FRAME of every recording** before it goes anywhere near a
  film, and confirm it shows the DAW and only the DAW. A mis-targeted match is
  silent: the tool picks the LARGEST matching window and records it happily.
- If the intended window is not in `--list`, STOP and shoot stills instead. Do
  not widen the match to make something appear.

## The narrator's avatar (the corner meter) — user spec, 2026-09-05

> *"very narrow lines, vertical bars, compress the whole thing, make it a little
> bit smaller … it is your face … as it talks all these bars shake according to
> the frequencies, and when you play music they reflect that … on shorts use a
> small one to avoid clipping usable content, on regular videos a bigger one …
> do not use it on intros because the intro already has the biggest avatar."*

Current geometry in `scripts/video/meter.py`, after the second refinement:

| | was | now |
|---|---|---|
| canvas | 404x61 | **340x48** |
| bands | 48 | **72** |
| line width | 0.55 of slot (~3.8 px) | **0.34 of slot (~1.5 px)** |
| Shorts | `SHORT_SCALE 0.62` | unchanged (211x30) |

⭐ **Already satisfied by the pipeline, do not re-implement:** `shortsmith.py`
passes `--start <introSeconds>` so the meter never draws over the intro (the
sting already IS this instrument at full size), and `--short` for a portrait
spec.

⚠️⚠️ **A DEFECT THIS UNCOVERED, AND IT WAS ALREADY SHIPPING.** Bands are log
spaced, so at the low end a band can be NARROWER THAN ONE FFT BIN and contain no
bin at all — the old code drew those as a permanent `0.0`. **MEASURED: 5 of the
old 48 bands were dead, centred at 36, 41, 52, 67 and 98 Hz** — the meter was
drawing silence exactly where the bass lessons live. At 72 bands it would have
been 11. Every empty band now falls back to the bin nearest its geometric
centre; re-measured after the fix, **0 of 72 bands are dead.**

⭐ **`shortsmith.py` now KEEPS the pre-meter master** as `<id>-nometer.mp4`. The
meter is burned in, so before this a restyle meant re-assembling the whole film —
burning a second meter over the first draws two.

⛔ **The three films finished BEFORE this change (mono-bass, chasing-14,
beethoven-128) carry the OLD meter** and have no kept master. They need one
re-assembly pass each to pick up the new avatar. Do that at the END of the wave,
not mid-film.

## The standard they are being rebuilt TO

`plugins/narrated-film/skills/narrated-film/SKILL.md` §"THE HOUSE STANDARD FOR A
LESSON" is authoritative. Worked example: `docs/research/design-b3-recut.md`.
In short: a novice opening (what it does · why you want it · how the demo
works), terms of art defined in plain words at first use, charts measured rather
than drawn, the playhead/derived-listen-window attention marker, `normalize:
false` on any A/B whose level difference is the lesson, and **no length cap —
the explanation decides; if something must go, cut a demonstration, never the
introduction.**

## ⚠️⚠️ The audibility problem these three have, MEASURED

Sub-100 Hz content as a share of each film's own level — the band a laptop
speaker barely reproduces (full RMS vs the same film low-passed at 100 Hz):

| film | full | <100 Hz | the problem |
|---|---|---|---|
| **Lesson 8 — Mono Your Bass** | −20.4 | **−27.1** (6.7 dB down) | the ENTIRE demonstration is a 60–110 Hz level difference |
| **Lesson 6 — Chasing −14** | −17.9 | −22.6 | its distortion is isolated at **−46.5 dBFS**, 28 dB under the film's own level |
| **Lesson 11 — Beethoven At 128** | −19.5 | −29.1 | the "18 dB of fundamental" claim is entirely sub-100 Hz |
| Lesson 10 — Strings That Breathe | −19.1 | −29.4 | least bass-dependent of the four |

**Lesson 8 is the clearest case and goes first:** its measured result (a 10.16 dB
mono fold in 60–110 Hz) lives in exactly the band the viewer's laptop cannot
deliver, so on the hardware they actually watch on they are largely not hearing
the thing the film demonstrates. That is the same fault as the compressor's
release chapter, in a different disguise.

⚠️ **Do not "fix" this by boosting the bass.** The honest treatments, in order:
show the fold as a **measured chart** (the mono sum's spectrum against the
stereo one, drawn from the renders); **add a mid-band consequence** the viewer
CAN hear on a small speaker if one genuinely exists in the material; and **say
plainly that this one needs headphones or a real speaker**, as a card, not a
gate.

## Order

1. **Lesson 8 — Mono Your Bass** (worst audibility fault; the pilot for this wave)
2. **Lesson 6 — Chasing −14** (a −46.5 dBFS claim, plus a natural matplotlib chart of four masters)
3. **Lesson 11 — Beethoven At 128** (sub-100 Hz claim)
4. **Lesson 4 — The Comma** (no audibility fault; a manim spiral-of-fifths diagram is the upgrade)
5. Lesson 5 — Bach House · 6. Lesson 7 — Beethoven's Metronome · 7. Lesson 9 — The Amen Break · 8. Lesson 10 — Strings That Breathe

⭐ **ONE AT A TIME.** There is a single staging app on port 17695; two film builds
driving it at once will corrupt each other's projects. Sequential, verified
before the next starts.

## What each rebuild must deliver

- The film, 1920×1080, `verify.py` green **including the new `A/B separation`
  check** (which is why these get rebuilt rather than patched — the gate needs
  the `.timeline.json` sidecar the current assembler writes).
- A retained `manifest.json` and build script under `scripts/video/lessons/<slug>/`,
  **so the next person is not in this position again.**
- Every on-screen number re-measured off the new render.
- ⛔ **NOT finalized and NOT published.** The shipped films stay untouched until
  the user has watched the rebuild and said so.
