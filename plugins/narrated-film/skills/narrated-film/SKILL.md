---
name: narrated-film
description: Turn screenshots, screen recordings and audio into a narrated video on your own machine — write a stage manifest, generate voice-over with a local TTS model in one consistent cloned voice, gate every line by transcribing it back, assemble with ffmpeg, and verify the finished file. Use for "make a demo video", "record a walkthrough", "narrate this feature", "turn these screenshots into a tutorial", or any request whose deliverable is a video.
---

# narrated-film — a finished video from stills, footage and audio

Screen-recording a walkthrough is long and dull; editing it is longer. This
builds the film instead, from a manifest of what to say and a folder of
pictures.

Nothing here talks to a cloud service and nothing needs an API key. The speech
model, the transcription model and ffmpeg all run locally.

**This skill does not capture anything.** Stills, footage and audio come from
wherever your project produces them — a screenshot tool, `ffmpeg -f
avfoundation`, an export from the thing you are demonstrating. Point the
assembler at the folders.

---

## Install

```bash
${CLAUDE_PLUGIN_ROOT}/install.sh              # venv + omlx + ~8 GB of models
${CLAUDE_PLUGIN_ROOT}/install.sh --no-models  # skip the download
```

Apple Silicon macOS, `python3` 3.11+, and `ffmpeg`/`ffprobe` (`brew install
ffmpeg`). The models are MLX builds, which is why the platform is narrow.

⚠️ **`omlx` is not on PyPI.** `pip install omlx` fails with *No matching
distribution found*, which reads exactly like the package not existing. It
installs only from git, which is what `install.sh` does — that one fact is most
of the reason the installer exists.

---

## Shape of a film

Each stage is up to two beats:

- **TALK** — narration over the *previous* stage's audio ducked to a bed
  (~0.16), while this stage's stills cut every few seconds.
- **PLAY** — this stage's own audio, clean and full, under footage.

The ducked bed is the single biggest quality win: it makes a slideshow feel
like one continuous piece instead of a stack of clips.

### Manifest

```json
{"video": {"width":1920,"height":1080,"fps":30,"cut":5.0,"bed":0.16,"playMax":14.0},
 "stages": [
   {"id":"01-intro","narration":"...","shots":["a.png","b.png"],"cut":3.4},
   {"id":"02-thing","narration":"...","shots":["thing.png"],
    "loop":"thing.wav","burst":"thing"},
   {"id":"03-fix","narration":"...","holdLast":true,
    "shots":["before.png","after.png"],
    "ab":{"before":"before.wav","afterShots":["after.png"],
          "cycles":2,"seconds":5.5}}
 ]}
```

- `cut` — seconds per still. ~3.4 for a fast tour, ~5 for ordinary footage.
- `holdLast` — stop cycling and hold the last still. **Use on every
  before/after stage**, or the stage ends showing the *un-fixed* picture after
  the voice has moved on.
- `loop` — a rendered wav of the audio at this point.
- `burst` — a directory of numbered frames plus `meta.json`
  (`{frames, seconds, fps}`), for real motion.
- `ab` — alternate this stage's audio against an earlier one, N times, with a
  BEFORE/AFTER badge. `beforeShots`/`afterShots` give each half its own
  picture; without them both halves show the same image and only the badge
  differs, which reads as a stuck video.

---

## The voice

⭐ **One reference clip, cloned for every line.** `assets/reference-voice.wav`
is sent as `ref_audio` on every request, so a whole film is one narrator with
no per-line steering.

⚠️ **Two models, two jobs — confusing them wastes hours.**

| model | job |
|---|---|
| **OmniVoice** | *design* a voice once, from a text description |
| **VoxCPM2** | *speak* every line, cloning that clip |

To design your own narrator, run `scripts/design-voice.py`, listen to the
candidates, copy the one you like over `assets/reference-voice.wav`, **and set
`REF_TEXT` in `narrate.py` to the exact words spoken in it.** A wrong
`REF_TEXT` degrades the clone badly, and it is the one thing a person changing
the voice always forgets.

⚠️ **Do not narrate with OmniVoice directly.** Measured twice: its `voice`
parameter routes to the model's *instruct* channel and this build **speaks the
description out loud** mid-sentence; and without sampling constraints it
collapses into babble that transcribes as nothing but "Thank you." Both
failures sound healthy to every level and pace check.

---

## ⚠️⚠️ The content gate — read this before trusting any output

**A level/pace/spectrum gate passes audio that says the wrong words.** Local
TTS gets words wrong often, and those failures all measure healthy. One
delivered film had three of five sampled lines transcribe as nothing but
"Thank you," and every meter said it was fine.

So `narrate.py` **transcribes every take with Whisper and compares it to the
script**, rejecting on level, pace, gibberish, reference leakage, truncation
and content mismatch. Best of N is kept.

A bug inside that gate worth knowing generally: `difflib.SequenceMatcher`'s
`autojunk` heuristic fires on any sequence over 200 elements and discards
everything occurring in more than 1% of it. Narration lines are 600–1000
*characters*, so character-level matching threw away the spaces and common
letters and **scored a verbatim take at 0.17**. The same take scores **0.91**
as word lists with `autojunk=False`. Controls on the fixed metric: identity
`1.00`, babble `0.016`, fluent-but-wrong text `0.014`.

**Control your metric before quoting a number it produced.**

⭐⭐ **An aggregate score cannot gate a short critical substring.** A greeting
scored **0.86** — well over the floor — while saying *"Diadavius, Proclawed
Opus five"* for "DAW Pro Claude Opus five". Four words out of forty cannot move
an aggregate, and those four were the only ones that had to be right. **If a
name, product or number must be exact, check for it explicitly**, and when a
recogniser mangles it, transcribe a known-good file first to find out whether
the fault is the speech or the transcription.

### Other languages

Set `LANG_CODE`. The `0.60` floor holds — Russian measured 0.68–0.98 — but
**spell numbers out as words in your script**: Whisper transliterates them back
differently, and the TTS reads them better.

---

## Workflow

```bash
P=${CLAUDE_PLUGIN_ROOT}
V=$P/.venv/bin

# ⚠️ PICK YOUR OWN PORT. Port 8000 is the default and therefore the collision.
# Two film builds have now killed each other's speech server on it, in both
# directions. Derive a port nobody else will pick and carry it in OMLX_BASE.
export OMLX_PORT=$((8000 + ($$ % 900) + 1))     # 8001-8900, yours
export OMLX_BASE=http://127.0.0.1:$OMLX_PORT
$V/omlx serve --port $OMLX_PORT & OMLX_PID=$!   # remember the PID YOU started

# 1. narration — one wav per stage id
OUT_DIR=./vo MANIFEST=./manifest.json LANG_CODE=en $V/python $P/scripts/narrate.py

# 2. assemble
$V/python $P/scripts/assemble.py --manifest ./manifest.json --vo ./vo \
    --out ./film.mp4 --shots ./shots --loops ./loops --bursts ./bursts \
    --intro ./intro.mp4 --outro ./outro.mp4

# 3. verify the FILE, not the parts
$V/python $P/scripts/verify.py --film ./film.mp4 --manifest ./manifest.json
```

⚠️ **Stop the speech server when you finish.** It holds tens of gigabytes while
reporting about 1 GB resident. Kill **the pid you started**, and prove the port
went free afterwards — a no-op kill is silent:

```bash
kill $OMLX_PID && lsof -nP -iTCP:$OMLX_PORT -sTCP:LISTEN   # must print nothing
```

⛔⛔ **NEVER KILL A SPEECH SERVER YOU DID NOT START.** Identifying it by port
proves *what* it is, not *whose* it is — and that distinction has cost real
work twice. A sibling build's server looks exactly like a leftover of your own.
If the pid on your port is not `$OMLX_PID`, **leave it alone**, move to another
port, and say so in your report.

⚠️ **What it costs when this goes wrong is not obvious.** Synthesis fails
loudly, which is fine. The content check does not: with the server gone
`verify.py` reports **BROKEN**, and the build does **not** block on BROKEN — so
a run silently drops from "8 checks ok" to "7 ok + 1 BROKEN" and still reports
success. **A BROKEN content check is not a passing content check.** If a build
lost its server partway, re-run `verify.py` with a live one before believing
any result from it.

---

## Branding

`brand.py` makes a reusable opening title and a closing copyright card;
`channel.py` makes an avatar, a banner and a horizontal lockup. **Both read
`brand.json`** — wordmark, sub-label, byline, copyright holder, disclaimer,
palette, fonts, and the bar heights of the mark itself. Copy `brand.json` into
your own project, edit it, and the cards are yours:

⚠️ **Pass `--brand` when you do.** The flag defaults to the copy that ships
*inside the plugin*, so a `brand.json` sitting beside your manifest is ignored
unless you name it — and the cards then render the placeholder wordmark
`YOUR BRAND` while passing every check in this kit. Both scripts print the brand
file they actually loaded; read that line rather than assuming.

```bash
$V/python $P/scripts/brand.py  intro --brand ./brand.json --audio sting.wav --out intro.mp4
$V/python $P/scripts/brand.py  outro --brand ./brand.json --out outro.mp4
$V/python $P/scripts/channel.py banner --brand ./brand.json --out banner.png --guides
```

⚠️ The cards must be **stream-compatible** with `assemble.py`'s concat, which
joins with `-c copy`. Mismatched fps, pixel format or SAR does not error — it
glitches on playback. Both cards go through the same encoder flags, so do not
re-encode them separately.

⚠️ The copyright holder and any URL are things this code **cannot know**. They
come from `brand.json` and the outro always prints back what it used. Do not
let it ship a guessed domain.

---

## Publishing

`scripts/publish.py` uploads the finished film, sets the thumbnail, files it in
a playlist (resolved BY TITLE, created if missing), then **reads the video back**
and asserts title, privacy and duration.

⚠️ **It defaults to `private`, and that is not merely a default.** Uploads from
an API project that has not passed YouTube's compliance audit are FORCED to
private whatever you ask for. `verify` reports that case as the audit lock
rather than as a mismatch.

⚠️ Scope is `.../auth/youtube`, NOT `youtube.upload` — **`playlistItems.insert`
does not accept `youtube.upload`**, so the narrow scope uploads and then fails
to file the video.

`validate` and `--dry-run` need no credentials and no network; everything else
does. Full setup, schema and limits: `PUBLISHING.md` in the plugin root.

---

## Verify the FILM, not the parts

The assembler cannot tell you it dropped a line. `verify.py` runs the checks
that each shipped as a defect once:

streams and duration · **A/V drift** (a padded concat join) · **distinct
frames** (a stuck slideshow) · **audio present** throughout · **loudness and
true peak** · **join seams** against a peak-to-inverted-peak control ·
**A/B separation** (below) · **transcribe-back** scored against its own script
*and a different stage's*.

⚠️⚠️ **A/B separation is the newest check and it exists because a DOCUMENTED
TRAP WITH NO GATE IS NOT FIXED.** `assemble.py` normalises each half of an A/B
separately unless the stage opts out; measured on one film, three chapters
shipped at `+0.00`, `+0.00` and `−2.20 LU` where their sources differed by
`−8.90`, `−1.60` and `+9.60`. The opt-out flag already existed *and its
docstring warned about exactly this in capitals* — three later chapters simply
never set it, and nothing measured the result. The check is a **comparison, not
a threshold**: it judges the film's delta against the SOURCE wavs' delta, so a
pair that genuinely does not differ still passes.

⚠️⚠️ **AND IT CHECKS THE AUDIO, NOT ONLY THE LEVEL — because a level test
cannot see two halves that are the SAME FILE.** MEASURED on a real film: a stage
whose BEFORE and AFTER both resolved to one wav passed GREEN at `+0.00 LU`,
correctly by the level test's own logic, because identical halves genuinely do
not differ in loudness. **The demonstration never happened and every gate said
ok**; a human reading `timeline.json` caught it. `assemble.py` takes BEFORE from
`ab["before"]` and AFTER from the stage's own `loop`, so pointing both at one
file is a one-character spec mistake whose only symptom is that the badge
changes. The check now also fails when the halves are the same audio (>40 dB
below signal), and reports a content figure for every pair — which is the ONLY
evidence available for a deliberately level-matched comparison (a beat-rate or
timbre demo), where loudness can never be evidence at all. It reads a
`.timeline.json`
sidecar the assembler writes, so it measures the **deliverable**, not the work
dir. Proven red on a flattened pair AND on an inverted one.

⭐ **Every check that could pass by doing nothing carries a positive control,
and a check whose control fails reports `BROKEN`, not `ok`.** Two of these were
caught by that discipline while the script was being written:

- The frame check originally **hashed** the PNGs and *passed a film that was a
  single still image* — h264 noise makes every extracted frame a different
  md5. Hashing answers "are these files identical", which is not the question.
  It compares pixels now, against a measured noise floor.
- The loudness check read ebur128's **first per-frame** value instead of the
  summary and reported **−70 LUFS** for a healthy film, because it opens on a
  title card and frame one is gated silence.

⚠️ `ffmpeg -v error` **suppresses** `astats`/`ebur128` summaries, which log at
INFO. Use `-hide_banner` when those numbers are the point — pairing `-v error`
with a command whose emptiness you intend to interpret turns a loud failure
into a quiet, clean, wrong answer.

---

## Editorial rules that came from a viewer, not a meter

⭐ **Feature panels belong in the intro only.** Cutting to an unrelated screen
mid-explanation is jarring. Once the subject is being built, stay on it.

⭐ **Except where the voice reads a value off a control** — then show that
control, and set `holdLast`.

⭐ **Write the numbers into the script from values you have read**, so the words
and the picture agree by construction rather than by luck.

⭐ **Show the change where it happens.** When the narration says what is being
adjusted, show the panel and the control, as a person doing it would.

⭐ **If a difference is subtle, say so.** A viewer who is told to expect a small
change hears it; a viewer promised a dramatic one hears a broken video.

---

## ⭐⭐ THE HOUSE STANDARD FOR A LESSON (adopted 2026-09-05)

The user watched the compressor lesson, said the format was right, and asked for
it to be the standard for every film that gets re-generated and every new one.
The worked example is `docs/research/design-b3-recut.md`; this is the method.

### Length is decided by the explanation, not the clock

> *"The time is not a hard constraint, the quality is what should define how much
> time we need for learning."* — the user, 2026-09-05

Let a lesson run as long as a balanced explanation needs. **If something has to
go, cut a demonstration — never the introduction.** The compressor lesson runs
10:07 and is better for it.

### Explainability is the goal; correctness is only the floor

> *"re-do with focus on explainability and quality, not fixed time, use all your
> nice tools and screen captures to make it better"* — the user, 2026-09-05

⭐ **Use the visual toolset generously.** manim for a mechanism or a curve,
matplotlib for a set of measurements, screen captures for the app doing the
actual work, and `scripts/video/screenrec/` (ScreenCaptureKit, built 2026-09-05)
for anything that MOVES — a control being dragged, a playhead sweeping. ⚠️ A
headless `captureUI` still photographs at ~3.5 fps and cannot film motion; that
is the ONLY reason to reach for the recorder, and it stays the exception. ⚠️ **A static frame with a voice over it is the failure mode** — if
a passage asserts something over a still, build the picture instead. A chapter
that is correct but that a novice could not follow is not finished.

### Open for a novice, every time

Assume someone learning the subject who has never used the control. Before any
demonstration: **what it does · why you would want that · how the demo will
work.** ⚠️ Never open as though continuing from something the viewer missed —
the first cut began "This is a compressor…" and read as the second half of a
video that does not exist. Define each term of art in plain words at first use,
in **every** chapter, not just the opening one.

### ⚠️⚠️ Check that what you claim is audible CAN BE HEARD

A viewer reported hearing no difference in two chapters. Both complaints were
measured afterwards and **both were correct, and neither was a speaker fault.**

⭐⭐ **A DIFFERENCE IN dB IS NOT A DIFFERENCE YOU CAN HEAR. Check the ABSOLUTE
LEVEL the difference lives at, not just its size.** One chapter's settings
differed by 11.5 dB and were inaudible, because the difference lived at −39.9 vs
−51.5 dBFS — 25–35 dB below the film's own level, under a laptop speaker's floor.

⭐ **Ask whether the effect is BOUNDED before you shoot a chapter about it.** The
other chapter's difference was capped by the plugin's own arithmetic at ~2.85 dB
against a ~1 dB loudness JND: **no signal and no setting could ever have made it
audible**, and that was derivable from the source in minutes.

In order of preference:

1. **Fix the source material.** Ducking is heard on something that *sits under*
   the hits, so a held pad moved that chapter's information up out of the floor.
2. **Carry it visually** — see the marker below.
3. **Say plainly that it cannot be heard, and make that the lesson** ("a soft
   knee is called gentle because it is gentle"). ⚠️ Never soften this into
   "listen closely" and never imply the viewer's ears or speakers are at fault.

**Headphones get a courtesy card, never a gate.** The visuals must carry it.

### ⚠️⚠️ Two mechanical traps that have now cost four films between them

**1. A CARD MUST BE ON SCREEN WHEN THE WORDS THAT READ ITS VALUE ARE SPOKEN —
and the still timer is NOT "evenly spread".** It is
`n = round(total / cut); each = total / n`, with `holdLast` clamping the list.
Guessing at this put a drum grid under the words "this is the lead melody", a
chart off screen while its numbers were read, and a card on screen 18 seconds
before the value it carries. ⭐ **The only reliable check is to pull the frame at
the moment the number is spoken and look at it** — use `silencedetect` to find
where each phrase actually runs. No gate sees this.

**2. A SPEECH-SERVER STALL IS NOT ABOUT LENGTH — and the retracted version of
this rule is a better lesson than the rule was.** A ~1,500-char stage once hung
Whisper for 20 minutes at 0 % CPU, ignored SIGTERM and needed `kill -9`. That
looked conclusive: it was the longest narration in the film and the only one that
hung, so "cap a stage at ~1,100 characters" was written down as a law. ⭐ **It was
FALSE.** Re-synthesising a 1,432-char text of the same shape on a quiet machine:
**38 s to speak, 1.0 s to transcribe.** The length was innocent; the stall was
resource contention.

⚠️⚠️ **THE SHAPE TO REMEMBER: a stall hands you a correlation and no mechanism,
and the biggest item is the most tempting thing to blame.** One confirming
instance, no control, and it was nearly installed as a rule that would have
shortened every future stage for nothing. **Do not write a law from a single
observation you have not tried to falsify.**

If a stage stalls: `lsof -nP -iTCP:$OMLX_PORT -sTCP:LISTEN` to see who is
there. **Kill it only if the pid is `$OMLX_PID` — the one you started.** Then
re-run the same command to prove the port is free — **a no-op kill is silent.**
`kill -9` only if SIGTERM is ignored. Never `pkill`/`pgrep`; this machine runs
other Python servers, and one of them may be another film build's.

### The attention marker — say WHEN to listen and WHERE

A playhead sweeping a **measured** chart at **real time** against the audio the
viewer is hearing, with the listen-windows shaded. ⚠️ The shaded windows are
**DERIVED from where the settings actually differ**, never chosen by eye — done
that way, the unshaded slivers land exactly on the moments where both settings
behave identically and there is nothing to hear. ⚠️ The animation's `run_time`
MUST equal the span of audio laid under it; a playhead on the wrong instant is
worse than no marker. Have the scene PRINT its sweep offsets and use those.

### Charts are MEASURED, not drawn

Divide the processed render by the dry one and plot the result. A hand-drawn
exponential looks identical to a viewer and is a lie in a film whose premise is
predict-then-measure. State the prediction and the measurement side by side —
one of ours predicted 1.5625 dB where the render measured 1.52.

⚠️ manim on this machine has **no LaTeX**: `Axes(include_numbers=True)` renders
through MathTex and crashes — place tick labels by hand as `Text`. A measurement
chart that refuses to say what its own scale is shipped in the first render of
both scenes. ⚠️ `Text("")` has no points and silently collapses a
`VGroup.arrange` into one overlapping stack — space with `buff`.

### ⚠️⚠️ `normalize: false` on any A/B whose level difference IS the lesson

`assemble.py` loudnorm-normalises **each half of an A/B separately** by default.
Three chapters shipped their entire demonstration flattened or inverted before
anyone measured it. **`check_ab_separation` in `verify.py` now gates this** — but
set the flag deliberately rather than waiting for the gate to catch you, and
pre-gain the pair with ONE shared static gain so the relative levels survive.
