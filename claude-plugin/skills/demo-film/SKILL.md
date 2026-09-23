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
`/v1/audio/transcriptions`. These were built against `omlx`.

⛔⛔ **THE SERVER SHIPS INSIDE THIS REPO. USE THE SCRIPT, NOT A HAND-ROLLED COMMAND.**

```bash
eval "$(claude-plugin/skills/demo-film/scripts/speech-server.sh start)"   # exports OMLX_BASE
…                                                                         # narrate.py
claude-plugin/skills/demo-film/scripts/speech-server.sh stop              # ALWAYS
```

It resolves the binary, **derives a private port**, blocks until the port
actually answers, and kills only the pid that owns that port.

**Where it really is:** `plugins/narrated-film/.venv/bin/omlx` — the
narrated-film plugin's own venv, in this repo. (A second copy exists at
`/Users/dsemenov/Views/llm/.venv/bin/omlx`; the in-repo one is canonical.)

⛔ **NEVER USE PORT 8000.** It is the default and therefore the collision — two
film builds have already killed each other's speech server on it, in both
directions. The script derives `8001-8900` per process and prints the matching
`OMLX_BASE`.

⛔ **`omlx` IS NOT ON `$PATH`, AND THAT IS NOT ABSENCE.** `which omlx` returns
nothing on a machine where everything is installed. **And do not probe
`import mlx_omni_server` — the package is `omlx`.** A wrong module name and a
missing package raise the IDENTICAL `ModuleNotFoundError`. A session ran exactly
those two probes, concluded the cloned voice needed gigabytes of downloads,
narrated a finished 10-chapter film with the macOS `say` voice, and told the
user the brand voice was unavailable. Everything was installed; the working
command was in shell history. The user's reply: *"we have even created the
skills to do just that, your memory is failing you!!!"* and *"everything is
inside repo, look at your skills!"*

**Never substitute a different voice.** One consistent cloned voice across every
film is the whole point of `assets/reference-voice.wav`. If the server will not
start, stop and say so — do not quietly ship another voice.

**Both models are already cached** in `~/.cache/huggingface/hub`:
`models--mlx-community--VoxCPM2-bf16` (TTS) and
`models--mlx-community--whisper-large-v3-turbo-asr-fp16` (the content gate's
STT). **Nothing needs downloading.** Verify with
`ls ~/.cache/huggingface/hub | grep -iE "voxcpm|whisper"` before ever concluding
a model is missing.

⚠️ **Kill it when you are done.** It holds tens of GB while reporting about 1 GB
resident — `speech-server.sh stop` does this by port, with the empty-pid case
guarded.

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

⚠️ **USE THE PLUGIN'S PYTHON, NOT `python3`.** `brand.py` needs Pillow, which the
system interpreter does not have — and the `ModuleNotFoundError` reads exactly
like the script being broken. `PY=plugins/narrated-film/.venv/bin/python`.

```bash
S=claude-plugin/skills
PY=plugins/narrated-film/.venv/bin/python

# 1. shots (see ui-capture)
node $S/ui-capture/scripts/panels.mjs shoot ./shots

# 2. ⭐ MOTION — record the app actually PLAYING. Not optional; see below.
scripts/video/screenrec/screenrec --app "<AppName>" --out ./rec/arrange.mp4 \
    --seconds 26 --fps 30                      # while the transport runs
ffmpeg -t 14 -i ./rec/arrange.mp4 -vf fps=30 ./bursts/arrange/f%04d.png
echo '{"fps":30}' > ./bursts/arrange/meta.json

# 3. ⭐ BRANDING — the opening title and the closing card. EASY TO FORGET.
eval "$($S/demo-film/scripts/speech-server.sh start)"
$PY $S/demo-film/scripts/brand.py intro --brand $S/demo-film/brand.json \
    --theme <theme> --audio ./sting.wav --seconds 5 --out ./brand/intro.mp4
$PY $S/demo-film/scripts/brand.py outro --brand $S/demo-film/brand.json \
    --theme <theme> --seconds 5 --out ./brand/outro.mp4

# 4. narration — one wav per stage id
OUT_DIR=./vo MANIFEST=./manifest.json LANG_CODE=en \
  $PY $S/demo-film/scripts/narrate.py
$S/demo-film/scripts/speech-server.sh stop

# 5. assemble — ⚠ PASS --intro AND --outro. A film without them is unfinished.
$PY $S/demo-film/scripts/assemble.py \
    --manifest ./manifest.json --vo ./vo --out ~/Movies/film.mp4 \
    --shots ./shots --loops ./loops --bursts ./bursts --work ./segments \
    --intro ./brand/intro.mp4 --outro ./brand/outro.mp4
```

### ⛔⛔ A FILM IS NOT A SLIDESHOW — and two ways to forget that

**① The intro and outro cards.** `brand.py` makes them and `assemble.py` takes
`--intro` / `--outro`. Both are OPTIONAL FLAGS, so omitting them produces a
perfectly valid file that is simply unbranded — no error, nothing to notice. A
film was delivered that way; the user's note was *"You forgot to use intro and
tail. Look at lessons or similar."* Every other wave under `scripts/video/`
(`lessons/`, `series/`, `comp/`) has `out/intro.mp4` and `out/outro.mp4` — if
yours does not, you forgot. **Pass `--brand`**, or the cards render the
placeholder wordmark `YOUR BRAND` while passing every check in this kit; both
scripts print the brand file they loaded, so read that line.

**② Stills cut on a timer are not motion.** `debug.captureUI` runs at about
**3.5 fps and cannot film movement at all**, so a "motion burst" built from it
is a time-lapse — a slideshow with extra steps. A 10-chapter film was delivered
as 35 stills flipping on a timer and the user said: *"you are just flipping
screenshots which is not good"* and *"you are not focusing on the track that
shows the playing track."*

⭐ **Record the app with the transport RUNNING** using
`scripts/video/screenrec/` (ScreenCaptureKit, real 30 fps) and feed those frames
as a `burst`, so every beat where music plays shows the playhead moving and the
meters lit. `captureUI` stays the DEFAULT for stills; this is the documented
EXCEPTION, for motion.

⚠️ **Before recording, rebuild the project with `--no-shots`** — or whatever your
builder's equivalent is — **so no editor card is left open.** Cards CANNOT be
closed (there is no close verb on the wire), so a card opened to be photographed
sits over the arrangement for the entire take. The first recording caught the
Poly Synth and Limiter cards parked on top of the playing track.

⚠️ **Verify the recording MOVES, with a control.** `freezedetect` on the take,
and the same probe on a deliberately static clip to prove the probe fires. A
valid-but-static mp4 is this project's characteristic failure shape.

**③ Every beat reusing the same footage and the same audio.** This is the one
that got a third cut rejected, so read it even if you think ① and ② are handled.
An observer measured **72 % of 9278 frames bit-frozen** and found eight "play"
beats built from **two** clips — two moments 187 s apart showing the same app
clock. Three mechanisms each default to *identical*, and nothing compared them:

- `play_audio()` trims `0:playMax` — **always the first N seconds**. Any two
  stages naming the same `loop` play byte-identical audio. Give each stage its
  **own excerpt file**, cut from its own place in the arrangement, or pass a
  distinct `playOffset`.
- `burst` is a directory NAME from the manifest. Two stages naming it get the
  same footage. **One burst dir per stage**, recorded at a different transport
  position / view / piece.
- ⛔ **A MISSING burst dir falls through to `stills()` SILENTLY.** A stage that
  never got recorded looks exactly like a stage that never wanted a recording.
  That is how the frozen beats shipped: the manifest named `arrange` and
  `mixer`, **neither directory existed**, and every one of those stages quietly
  became a slideshow.

⭐ `assemble.py` now **refuses to build** when two stages share a burst dir or a
`(loop, offset)` pair. Keep that gate. *"Nothing compares one beat to another,
so identical beats are the default, not an accident."*

### ⛔ SILENCE THE OUTPUT DEVICE, NOT THE MASTER FADER

Playback during a recording goes through the real device with the user sitting
there. The obvious fix — `mixer.setMasterVolume {volume: 0}` — **puts `-inf dB`
on the master strip in your footage** while music is plainly audible to the
viewer. That shipped in three places in one film. A dead master fader reads as a
bug report, not a demo.

Route the **staging app** to a virtual device instead:

```js
await cmd("output.setDevice", { uid: "BlackHole2ch_UID" });   // `uid` is the ONLY key
const { devices } = await cmd("output.listDevices", {});
if (!devices.find(d => d.isSelected)?.uid === "BlackHole2ch_UID") process.exit(2);
```

⚠️ **BY UID** — the numeric device id changes on every `coreaudiod` restart.
⚠️ The selected-device flag is **`isSelected`**, not `current` (there is no
`current` field; looking for one reads as "nothing selected").
⚠️ `isDefault` is a **different** field and stays on the user's own output —
this moves staging only. **Never change the system default or a user device.**
⚠️ **Refuse to play if the read-back does not confirm the route.** Otherwise a
failed setter means full-volume playback out of the user's speakers.

### ⛔ TIE PICTURE CHANGES TO SENTENCES, NOT A STOPWATCH

`stills()` computes `n = round(total / cut)` and divides the time **evenly** —
it never reads the words. Eight sentences of 0.47–3.69 s over a fixed 2.133 s
timer put **"A saturator" over the PHASER card** and "A phaser" over HALL
REVERB. For a demo that is the worst class of error: it teaches the wrong thing,
confidently, and every gate passes.

Put an auditable `cutOn` (sentence indices where the next still appears) in the
manifest and convert it to `cutAt` seconds against the recorded narration. Print
the sentence→shot table and **read it** before assembling.

### ⛔ A BOILERPLATE LINE IS AN ASSERTION ABOUT THE ARTIFACT

`brand.py` stamped brand.json's `disclaimer` ("Narration is a synthetic voice")
on **every** outro. Six wordless visualisers shipped that line. Pass
`--no-disclaimer` for anything with no speech in it — or make the line
conditional. Boilerplate that is not checked against the file eventually ships
as a lie.

### ⛔ A NARRATED NUMBER IS A CLAIM WITH AN EXPIRY DATE

If a line says *"the drop is six decibels louder and thirty three decibels
brighter"*, that sentence is only true of the render it was measured against.
Change an instrument and both figures move — but `narrate.py` **keeps any
existing take over 20 KB**, so the old words are re-spoken over the new music
and nothing downstream compares them. The film then states a false measurement
in a confident voice, over a picture of the thing it is wrong about.

`sync-claims.py` closes this: measure the fresh render, rewrite the sentence if
the figures moved, and **move the stale wav to `vo/rejected/`** so narration is
forced to re-record it. Run it after every build, before narrating. Any spoken
number needs this treatment, not just this one.

### ⛔ CHECK HOW A SCRIPT TAKES ITS CONFIGURATION BEFORE WIRING IT IN

`narrate.py` has **no argparse** — it reads `MANIFEST`, `OUT_DIR`, `OMLX_BASE`,
`REF_WAV` from the environment. It was being invoked with
`--manifest ... --out ...`; Python ignored both flags in silence, defaulted
`OUT_DIR` to `./vo`, and the assembler went on reading the previous cut's voice
takes from the real `vo/`. Every gate passed. An unrecognised flag is only an
error when something is there to reject it.

### ⛔ MOTION IS NOT ALWAYS THE RIGHT ANSWER — BUT OPTING OUT IS A DECLARATION

A beat whose audio is a *rendered demonstration* — isolated hits, a swept tone,
an A/B — must not run footage of a full arrangement underneath. Those are two
different performances, and the viewer can hear that they do not line up. A
still claims nothing; motion there claims something false.

So such a stage sets **`"stillsOnly": true`**, and the recording gate accepts
that. What it must never accept is a stage with no burst and no flag — a stage
that *lost* its recording has to stay distinguishable from one that never wanted
it, or you ship an 18-second frozen frame again.

### ⛔ CALIBRATE A GATE AGAINST A KNOWN-BAD ARTEFACT, OR DO NOT TRUST IT

`freezedetect=n=-60dB:d=2` flagged every take on every run while the footage was
demonstrably moving — a DAW window is ~95% static chrome, so the mean
frame-to-frame difference is always tiny. Sweeping −60 dB to −30 dB showed there
is **no threshold** at which real takes read clean and a frozen clip reads
frozen: the probe could not do the job at any setting. Do not tune a probe like
that; replace it. The working one is peak pixel difference between frames 16 s
apart (`blend=all_mode=difference,signalstats` YMAX): real 181–255, frozen 3.

A gate that cries wolf every run is worse than no gate — it teaches you to
scroll past the one time it is right.

### ⛔ SCREEN CAPTURE SILENTLY RETURNS ZERO FRAMES WHEN THE DISPLAY SLEEPS

ScreenCaptureKit keeps finding the window, keeps reporting its size, and writes
a valid mp4 containing nothing. On an unattended machine every take after the
display sleeps is a valid-looking file of nothing. Hold it awake for the whole
run: `caffeinate -d -i -u -w $$ &` (`-u` also **wakes** a display that already
slept; `-w $$` ties it to the script so nothing is left holding the machine on).

### ⛔ AN ITERATIVE FIX MUST ITERATE ON THE SOURCE, NOT ITS OWN OUTPUT

`assemble.py`'s true-peak trim re-encoded AAC each pass and fed the result back
in. Generation loss then drove it the wrong way — −0.70 → −0.80 → −0.90 →
**+1.20 dBTP**, a 0.10 dB *reduction* raising the peak by 2.1 dB — and the run
died "would not converge" on a mix that was fine. Accumulate one total trim and
apply it to the untouched render every time. Any loop with a lossy step inside
it has this bug waiting.

### ⛔ A COMPLETION BANNER MUST CARRY THE VERDICT

A build loop ended with an unconditional `echo "ALL BUILDS COMPLETE"` and a
waiter polled for that string. Two of six builds had failed; both logged
`exit=1`; the banner printed anyway and the waiter reported success. Track `rc`
and print OK **or** FAILED. And compare mtimes — a stale output from a previous
run sits in place looking exactly like fresh output.

### ⛔⛔ BUILD INTO THE REPO, NEVER INTO THE SESSION SCRATCHPAD

The scratchpad path contains the **session UUID**. A film built there exists in
exactly one directory that the next session cannot name and a cleanup can take.
Worse, the scripts still *run*: next session they read an absent tree, rebuild
from nothing, and look like they worked.

Give every script one base definition, overridable and defaulting to its own
directory — resolved from the **script**, not the cwd:

```bash
FILM="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"          # shell
```
```js
const DIR = process.env.FEATURES_HOME                             // ESM
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
```

Then add the output dirs to `.gitignore` — renders are regenerated, never source.

Two traps found while rescuing one of these (2026-09-21):

- **Never `rsync` a scratchpad over the repo.** It holds *older copies of the
  scripts too*; the mirror silently reverted a day of fixes (`build.mjs`
  26,046 → 21,028 B). Copy the artifact subtrees **by name**.
- **`du -sh` is not a copy gate.** It disagreed on three of eight subtrees that
  were in fact byte-identical. Count files **and** sum bytes; md5 the headline
  artefact, with a negative control on something that should differ.

Keep any superseded tree as `out-superseded-<date>/` and say in the deliverables
doc what it is. An old film beside a new one, with nothing to tell them apart,
is worse than either.

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
- `playOffset` — **seconds into `loop` to start from.** Defaults to 0, and two
  stages with the same `loop` and the same offset play byte-identical audio —
  which `assemble.py` now refuses to build. Prefer a separate excerpt file per
  stage; use the offset when one long render has to serve several beats.
- `burst` — a directory under `--bursts`, holding **either** `clip.mp4` (a
  screen recording, preferred) **or** numbered frames `f%04d.png` plus
  `meta.json` (`{frames, seconds, fps}`). One directory per stage; a recording
  left at `out/rec/<stage>.mp4` is **invisible** until it is placed at
  `bursts/<stage>/clip.mp4`.
- `cutOn` — sentence indices at which the next still appears, so the picture
  changes **on the narration** instead of on a timer. `cutOn` has one fewer
  entry than `shots`. Converted to `cutAt` (seconds) against the recorded
  narration; `assemble.py` reads `cutAt`.
- `cutAt` — generated, not hand-written. Print the sentence→shot table and read
  it before assembling.

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
