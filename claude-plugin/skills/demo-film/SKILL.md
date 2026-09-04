---
name: demo-film
description: Turn a DAW Pro session into a narrated video — write a stage manifest, generate voice-over with a local TTS model in one consistent cloned voice, gate every line by transcribing it back, and assemble stills, live playback footage and audio loops into a finished film. Use for "make a demo video", "record a tutorial", "narrate what you just built", "produce a lesson about this track", or any request whose deliverable is a video.
---

# /demo-film — narrated video from a DAW Pro session

Screen-recording a session is long and dull; editing it is longer. This builds
the film instead: a manifest of what to say, screenshots from `ui-capture`,
short rendered audio loops of the music as it grows, and real footage of the
transport running — assembled by ffmpeg with a narration track in one
consistent voice.

Read **`ui-capture`** first for the screenshots; this skill assumes you have
them.

---

## Shape of a film

Each stage is up to two beats:

- **TALK** — narration over the *previous* stage's audio ducked to about 0.16,
  while the stage's stills cut every few seconds. The ducked bed is the single
  biggest quality win: it makes a slideshow feel like one continuous piece
  instead of a stack of clips.
- **PLAY** — this stage's audio, clean and full, under real footage of the
  transport moving.

So the viewer hears the track grow one instrument at a time, and each new
element arrives *after* the sentence explaining it.

---

## The voice

⭐ **One reference clip, cloned for every line.** `assets/reference-voice.wav`
is the narrator used in the shipped films — a warm, unhurried male teacher.
`narrate.py` sends it as `ref_audio` on every request, so all lines match
without any per-line voice steering.

⚠️ **Two different models are involved, and confusing them wastes hours.**
The reference clip was *designed* by **OmniVoice**, which can invent a voice
from a text description. The narration is *synthesised* by **VoxCPM2**, which
clones the clip. OmniVoice is not used for the narration itself, and that is a
measured decision, not a preference:

| model | role | why |
|---|---|---|
| OmniVoice | design the voice once, from a description | it is the one that can do this |
| VoxCPM2 | speak every line, cloning that clip | it says the right words |

Driving OmniVoice directly for narration failed two ways. Its `voice` parameter
is routed to the model's *instruct* channel, and the build **spoke the
description out loud** mid-sentence ("gentle, encouraging and clear"). And
without explicit sampling constraints it collapsed into babble that Whisper
transcribes as nothing but "Thank you." Both failures produce audio that passes
every level and pace check.

`REF_TEXT` must be the exact words spoken in the reference clip. A wrong one
degrades the clone badly.

### Server

Any OpenAI-compatible local speech server with `/v1/audio/speech` and
`/v1/audio/transcriptions`. These were built against `omlx`:

```bash
omlx serve --port 8000          # then set OMLX_BASE if not 127.0.0.1:8000
```

⚠️ **Kill it when you are done.** It holds tens of GB while reporting about 1 GB
resident. Find the pid by PORT, never by name, and kill that pid only.

---

## ⚠️⚠️ The content gate — the most important thing here

**A level/pace/spectrum gate passes audio that says the wrong words.** Local TTS
gets the words wrong often, and every one of those failures measures healthy.
One delivered film had three of five sampled lines transcribe as nothing but
"Thank you."

So `narrate.py` **transcribes every take with Whisper and compares it to the
script**, rejecting on level, pace, gibberish, reference/description leakage,
truncation, and content mismatch. Best of N is kept.

### The bug inside the gate, which is worth knowing about on its own

`difflib.SequenceMatcher`'s `autojunk` heuristic fires on any sequence longer
than **200 elements** and discards every element occurring in more than 1% of
it. Narration lines are 600–1000 *characters*, so character-level matching
throws away the spaces and common letters and **scored a verbatim take at
0.17**. The same take scores **0.91** compared as word lists with
`autojunk=False`.

Measured on the fixed metric: identity `1.00`, babble ("Thank you.") `0.016`,
fluent-but-wrong English `0.014`. A floor of `0.60` sits clear of both.

⭐ **Control the metric before you quote a number it produced.** Three narration
sets were once ranked 0.27 / 0.52 / 0.79 by the broken call and those figures
were reported as measurements. They were noise.

### Non-English

The floor works for any language, but Whisper transliterates: it writes "126"
and "Tech House" where a Russian script spells them in Cyrillic words. That
costs a few words, not the comparison — Russian narration measured 0.68–0.98
against the same 0.60 floor. **Spell numbers out in words in the script**, which
also makes the TTS read them correctly.

---

## Workflow

```bash
S=claude-plugin/skills

# 1. shots (see ui-capture)
node $S/ui-capture/scripts/panels.mjs shoot ./shots

# 2. narration — one wav per stage id
OUT_DIR=./vo MANIFEST=./manifest.json LANG_CODE=en \
  python3 $S/demo-film/scripts/narrate.py

# 3. assemble
python3 $S/demo-film/scripts/assemble.py \
    --manifest ./manifest.json --vo ./vo --out ~/Movies/film.mp4 \
    --shots ./shots --loops ./loops --bursts ./bursts --work ./segments
```

### Manifest

```json
{"video": {"width":1920,"height":1080,"fps":30,"cut":5.0,"bed":0.16,"playMax":14.0},
 "stages": [
   {"id":"01-intro","narration":"...","shots":["t01-arrange.png"],"cut":3.4},
   {"id":"02-kick","narration":"...","shots":["02-kick.png"],
    "loop":"02-kick.wav","burst":"02-kick"},
   {"id":"03-comp","narration":"...","holdLast":true,
    "shots":["03-arrange.png","comp-before.png","comp-after.png"]}
 ]}
```

- `cut` — seconds per still. Use ~3.4 for a fast feature tour, ~5 for ordinary
  footage.
- `holdLast` — stop cycling and hold the final still. **Use it on every
  before/after stage**, or the stills wrap around and the stage ends showing
  the *un-tuned* panel after the voice has moved on.
- `loop` — a rendered wav of the music at this point.
- `burst` — a directory of numbered frames plus `meta.json` (`{frames, seconds,
  fps}`), captured while the transport runs.

---

## Editorial rules that came from a viewer, not a meter

⭐ **Feature panels belong in the intro only.** Cutting to a picker or a quantize
panel in the middle of building a track is jarring — it shows something with
nothing to do with the project on screen. Once the music starts being built,
stay on the project.

⭐ **Except where the voice reads a value off a control.** "Attack eight
milliseconds, release ninety" should be on screen while it is said, and it
should be *that* control on *this* project. Open the stage on its own
screenshot first so the panel is a reveal, not a cutaway.

⭐ **Write the numbers into the script and then match them.** Read the live
values before writing narration; then panel and voice agree by construction
rather than by luck.

---

## Verify the FILM, not the parts

The assembler cannot tell you it dropped a line. **Run `verify.py` on the
finished file** — it carries every check below with a positive control on each:

```bash
python3 $S/demo-film/scripts/verify.py --film film.mp4 \
    --manifest manifest.json \
    --joins 5.0,17.02
```

streams and duration · A/V drift · **distinct frames** (a stuck slideshow) ·
audio present throughout · loudness and true peak · join seams ·
**transcribe-back** scored against its own script *and a different stage's*.

⚠️⚠️ **Do NOT hash frames to detect a stuck slideshow.** This skill used to
teach exactly that — extract PNGs, `md5 -q | sort -u | wc -l` — and it
**passed a film that was a single still image**: h264 noise makes every
extracted frame a different md5, so the hashes always differ. Hashing answers
"are these files identical", which is not the question. `verify.py` compares
pixels against a measured noise floor instead.

⭐ **The transcribe-back needs its control**: score each stage against its own
script *and against a different stage's*. Without the second number a high
score proves nothing. Measured on a good film: 0.79 against its own line, 0.04
against another's.

⭐ A check whose own control fails reports `BROKEN`, not `ok`. Exit code is `0`
all-passed, `1` a real failure, `2` only broken probes.

⚠️ `ffmpeg -v error` **suppresses** `astats`/`ebur128` summaries, which log at
INFO. Use `-hide_banner` when those numbers are the point.
