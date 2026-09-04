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

$V/omlx serve --port 8000 &        # leave running; see the warning below

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
reporting about 1 GB resident. Find it **by port, never by name**, and kill that
pid only:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN     # add -t for just the pid
```

If something already owns port 8000, serve elsewhere and set
`OMLX_BASE=http://127.0.0.1:<port>`.

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
**transcribe-back** scored against its own script *and a different stage's*.

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
