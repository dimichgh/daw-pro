# Narrated Film Kit

Turn screenshots, screen recordings and audio into a finished narrated video,
on your own machine, with no cloud service and no API key.

Install it as a Claude Code plugin and an agent will drive it for you, or run
the scripts directly — they have no dependency on Claude Code, and none on any
particular application.

```
install.sh                 prerequisites, venv, omlx, and the three models
brand.json                 your identity: wordmark, holder, palette, the mark
assets/
  reference-voice.wav      the narrator: a patient male teacher (13.8 s)
  reference-voice.mp3      the same clip, listenable
scripts/
  narrate.py               manifest -> one wav per stage, content-gated
  assemble.py              stills + loops + footage + narration -> film
  verify.py                check the finished film, every probe controlled
  brand.py                 reusable intro title and closing copyright card
  channel.py               avatar, banner and horizontal lockup
  design-voice.py          invent a NEW narrator from a written description
  publish.py               upload to YouTube and verify it arrived (see
                           PUBLISHING.md; optional deps, `install.sh --publish`)
skills/narrated-film/      the skill Claude Code loads
agents/film-director.md    the agent that writes and assembles a film
example/
  manifest.json            a two-stage film you can build to check the install
```

## Install

As a plugin:

```
/plugin marketplace add dimichgh/daw-pro
/plugin install narrated-film@daw-pro
```

Then, once, for the models and the local speech server:

```bash
./install.sh                 # ~8 GB of models
./install.sh --no-models     # skip the download
```

Apple Silicon macOS. Needs `python3` 3.11+ and `ffmpeg`/`ffprobe`
(`brew install ffmpeg`). The models are MLX builds, which is what makes the
platform narrow.

⚠️ **`omlx` is not on PyPI** — `pip install omlx` fails with *No matching
distribution found*, which reads exactly like the package not existing. It
installs only from `git+https://github.com/jundot/omlx`, which is what
`install.sh` does. Some revisions also cap `requires-python` at `<3.14`; the
installer prefers a 3.11–3.13 interpreter when it can find one and otherwise
retries past the bound, which is measured working on 3.14.

⚠️ **The models are not vendored.** VoxCPM2 (4.6 GB), OmniVoice (2.0 GB) and
Whisper large-v3-turbo (1.5 GB) come from Hugging Face at install time. Eight
gigabytes of weights do not belong in a git repository, and they are the same
public builds for everyone.

## Use

```bash
V=./.venv/bin
$V/omlx serve --port 8000 &          # leave running

OUT_DIR=./vo MANIFEST=./example/manifest.json $V/python scripts/narrate.py
$V/python scripts/assemble.py --manifest ./example/manifest.json \
    --vo ./vo --out ./test.mp4 --shots ./example --loops ./example
$V/python scripts/verify.py --film ./test.mp4 --manifest ./example/manifest.json
```

⚠️ **Stop the server when you finish.** It holds tens of gigabytes while
reporting about 1 GB resident. Find it by **port**, never by name, and kill that
pid only:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN
kill <pid>
```

If something already owns port 8000, serve elsewhere and set
`OMLX_BASE=http://127.0.0.1:<port>`.

## Where the pictures come from

**This kit does not capture anything.** Stills, footage and audio come from
wherever your project produces them — a screenshot tool, `ffmpeg -f
avfoundation -i "1"`, an export from the thing you are demonstrating. Point
`assemble.py` at the folders with `--shots`, `--loops` and `--bursts`.

That is deliberate. Capture is the part that differs completely between
projects; everything after it is the same work every time.

## The voice

`assets/reference-voice.wav` is cloned on every line, so a whole film is one
consistent narrator with no per-line steering.

**Two models, two jobs — confusing them wastes hours:**

| model | job |
|---|---|
| **OmniVoice** | *design* a voice once, from a text description |
| **VoxCPM2** | *speak* every line, cloning that clip |

To design your own narrator, run `scripts/design-voice.py`, listen to the
candidates, copy the WAV you like over `assets/reference-voice.wav`, **and set
`REF_TEXT` in `narrate.py` to the exact words spoken in it.**

⚠️ `REF_TEXT` currently names a product because it is the literal transcript of
the shipped clip. It is not a template. Editing it without replacing the audio
degrades every line the model speaks — and the result still passes the content
gate.

⚠️ **Do not narrate a film with OmniVoice directly.** Measured, twice: its
`voice` parameter is routed to the model's *instruct* channel and this build
**speaks the description out loud** mid-sentence; and without explicit sampling
constraints it collapses into babble that transcribes as nothing but
"Thank you." Both failures sound like a working file to every level and pace
check.

## ⚠️⚠️ The content gate — read this before trusting any output

**A level/pace/spectrum gate passes audio that says the wrong words.** Local TTS
gets the words wrong often, and those failures all measure healthy. One
delivered film had three of five sampled lines transcribe as nothing but
"Thank you," and every meter said it was fine.

So `narrate.py` **transcribes every take with Whisper and compares it to the
script**, rejecting on level, pace, gibberish, description/reference leakage,
truncation, and content mismatch. Best of N is kept.

There is a bug inside that gate worth knowing about generally:
`difflib.SequenceMatcher`'s `autojunk` heuristic fires on any sequence longer
than 200 elements and discards everything occurring in more than 1% of it.
Narration lines are 600–1000 *characters*, so character-level matching threw
away the spaces and common letters and **scored a verbatim take at 0.17**. The
same take scores **0.91** compared as word lists with `autojunk=False`.
Controls on the fixed metric: identity `1.00`, babble `0.016`, fluent-but-wrong
text `0.014`.

**Control your metric before quoting a number it produced.**

⭐ **And an aggregate score cannot gate a short critical substring.** A greeting
scored 0.86 — well over the 0.60 floor — while mangling the four-word product
name inside it. Four words out of forty cannot move an aggregate. If a name or
a number must be exact, check for it explicitly.

### Other languages

Set `LANG_CODE`. The `0.60` floor holds — Russian narration measured 0.68–0.98
— but **spell numbers out as words in your script**, both because Whisper
transliterates them back differently and because the TTS reads them better.

## Manifest

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

Each stage becomes up to two beats: **TALK** (narration over the previous
stage's audio ducked to a bed, stills cutting on a timer) and **PLAY** (this
stage's audio clean, under footage). The ducked bed is the single biggest
quality win — it makes a slideshow feel continuous.

- `cut` — seconds per still; ~3.4 for a fast tour, ~5 for ordinary footage.
- `holdLast` — stop cycling and hold the last still. **Use on every before/after
  stage**, or the stage ends showing the *un-fixed* picture.
- `loop` — a rendered wav of the audio at this point.
- `burst` — a directory of numbered frames plus `meta.json` (`{frames, seconds,
  fps}`).
- `ab` — alternate this stage's audio against an earlier one with a
  BEFORE/AFTER badge. `beforeShots`/`afterShots` give each half its own picture;
  without them both halves show the same image and only the badge differs,
  which reads as a stuck video.

## Branding

`brand.py` renders a reusable opening title and a closing copyright card;
`channel.py` renders an avatar, a banner and a horizontal lockup. Both read
**`brand.json`** — wordmark, sub-label, byline, copyright holder, disclaimer,
palette, fonts, and `markBars`, the bar heights of the mark itself. Copy it into
your project, edit it, and everything is yours:

⚠️ **`--brand` defaults to the copy inside the plugin**, so name your own file
explicitly or the cards render the placeholder wordmark `YOUR BRAND` — and pass
every check while doing it. Both scripts print the brand file they loaded.

```bash
$V/python scripts/brand.py  intro --brand ./brand.json --audio sting.wav --out intro.mp4
$V/python scripts/brand.py  outro --brand ./brand.json --out outro.mp4
$V/python scripts/channel.py banner --brand ./brand.json --out banner.png --guides
```

⚠️ The cards must stay **stream-compatible** with `assemble.py`'s concat, which
joins with `-c copy`. Mismatched fps, pixel format or SAR does not error — it
glitches on playback.

⚠️ The copyright holder and any URL are things this code cannot know. They come
from `brand.json`, and the outro always prints back what it used, so a guessed
domain cannot ship quietly.

## Publishing

`scripts/publish.py` uploads a finished film, sets its thumbnail, files it in a
playlist and reads the video back to prove it landed. It defaults to **private**,
and an unaudited API project is forced to private regardless — see
**[PUBLISHING.md](PUBLISHING.md)** for the one-time Google Cloud setup, the
metadata schema and what is and is not proven.

```bash
$V/python scripts/publish.py validate --film film.mp4 --meta publish.json
$V/python scripts/publish.py upload   --film film.mp4 --meta publish.json --dry-run
```

## Verify the film, not the parts

The assembler cannot tell you it dropped a line.

```bash
$V/python scripts/verify.py --film film.mp4 --manifest manifest.json \
    --joins 5.0,17.02
```

Checks: streams and duration · A/V drift (a padded concat join) · distinct
frames (a stuck slideshow) · audio present throughout · loudness and true peak ·
join seams · transcribe-back scored against its own script **and a different
stage's**.

⭐ **Every check that could pass by doing nothing carries a positive control**,
and a check whose control fails reports `BROKEN` rather than `ok`. Exit code is
`0` all-passed, `1` a real failure, `2` only broken probes.

Two false results were caught by that discipline while the script was being
written, and both are the reason it exists:

- The frame check originally **hashed** the PNGs, and **passed a film that was
  a single still image** — h264 noise makes every extracted frame a different
  md5. Hashing answers "are these files identical", which is not the question.
- The loudness check read ebur128's **first per-frame** value instead of the
  summary and reported **−70 LUFS** for a healthy film, because the film opens
  on a title card and frame one is gated silence.

⚠️ `ffmpeg -v error` **suppresses** `astats`/`ebur128` summaries, which log at
INFO. Use `-hide_banner` when those numbers are the point.
