# Voice film — "What's new: tune a voice, sing your words"

A ~5.5-minute narrated film of DAW Pro's voice features, built for a novice. It covers an
original song ("Light On", D major, 100 BPM) composed on camera; lyrics applied to the Lead
notes; the built-in singer; the note editor; Tune to Melody; Natural vs Hard Tune; Keep voice
size; and the Voice tool. What is final is listed in `DELIVERABLES.md`. The brief is `BRIEF.md`.

Everything here talks to a **staging** app on **17695** that this folder launches itself.
**17600 is the user's live app: nothing here names it.** Python below means
`/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python` (it has Pillow and numpy).

## Rebuild, in order

| # | Step | Command (run in this folder) | Writes |
|---|---|---|---|
| 1 | Private singing runtime (symlinks the installed engine, copies the built-in voice, checks shas) | `bash sing-runtime.sh` | `work/sing-runtime/` |
| 2 | Staging, PARKED (the launcher is the stop button) | `nohup node start-staging.mjs > staging.log 2>&1 &` | `staging.json`, `staging.pid` |
| 3 | The song, layer by layer, with stills | `node build-song.mjs` | `out/shots/s01–s05`, project |
| 4 | Lyrics onto the Lead notes + the built-in singer (seed 2611) | `node sing.mjs` | `out/shots/s06–s10`, `work/cp1-sung.dawproj` |
| 5 | Chapters 3–6: editor, sour-on-purpose, Tune to Melody, Hard Tune, octave, Voice tool | `node tune.mjs` | `out/shots/t01–t16`, `work/states/*`, `work/quotes-tune.json` |
| 6 | Build-up states for the opening takes | `node derive-states.mjs` | `work/states/s-drums,s-band,s-lead` |
| 7 | Mute the piano Lead after the voice arrives (audio proven unchanged) | `node mute-lead.mjs` | states re-saved |
| 8 | Every render, from the saved states only | `node render-all.mjs` | `out/renders/*.wav` |
| 9 | The spoken numbers (each reader runs a control first) | `node measure.mjs` | `work/measure/summary.json` |
| 10 | One excerpt per beat, one static gain per beat/pair | `python cut-loops.py` | `loops/*.wav`, `loops/cuts.json` |
| 11 | Screen takes (motion beats only), plus a motion check | `bash record-all.sh [burst…]` | `bursts/<b>/raw.mp4` |
| 12 | Read the transport clock in each take BY EYE | `CLOCK_FILE=raw.mp4 python tools/clock-montage.py work/clocks.png <bursts…>`, then type the readings into `work/take-clock.json` | |
| 13 | Trim each take to its excerpt's first sample | `python sync-takes.py` (check with `CLOCK_FILE=clip.mp4 …clock-montage.py`) | `bursts/<b>/clip.mp4` |
| 14 | Narration (the ONE cloned voice; in-repo omlx, never port 8000) | see below | `vo/*.wav`, `work/content-gate.json` |
| 15 | Picture cuts aligned to the narration's pauses | `node sync-cuts.mjs` | `cutAt` in `manifest.json` |
| 16 | Brand cards | see below | `out/brand/intro.mp4`, `outro.mp4` |
| 17 | Assemble | see below | `out/voice-film.mp4` + `.timeline.json` |
| 18 | Gates | see below | `logs/verify.log`, `work/*.json` |
| 19 | Chapters + draft metadata | `python tools/chapters.py` | `publish/` |

Steps 3–5 are the only ones that make new audio. **Re-running 4 makes a new take, and every
number in the narration then has to be re-measured (step 9) and re-spoken.**

### Narration (step 14)
```bash
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
SS=/Users/dsemenov/Views/daw-pro/claude-plugin/skills/demo-film/scripts/speech-server.sh
eval "$($SS start)"          # exports OMLX_BASE on a private port
ATTEMPTS=6 MANIFEST=manifest.json OUT_DIR=vo $PY /Users/dsemenov/Views/daw-pro/claude-plugin/skills/demo-film/scripts/narrate.py
$PY tools/content-gate.py    # re-transcribes every kept take -> work/content-gate.json
OMLX_PORT=${OMLX_BASE##*:} $SS stop     # ALWAYS: it holds tens of GB
```
narrate.py keeps existing takes. To re-speak one line, move its `vo/<id>.wav` aside first.

### Brand (step 16)
```bash
B=/Users/dsemenov/Views/daw-pro/claude-plugin/skills/demo-film; R=/Users/dsemenov/Views/daw-pro
$PY $B/scripts/brand.py intro --brand $B/brand.json --theme features --size 1920x1080 --seconds 3.5 --out out/brand/intro.mp4
$PY $B/scripts/brand.py outro --brand $B/brand.json --theme features --size 1920x1080 --seconds 5 \
    --no-disclaimer --line2 "Narration and singing are synthetic voices. Every figure on screen is measured." --out out/brand/outro.mp4
```
⚠ `--no-disclaimer` is deliberate. The brand's stock line says "No music-generation model was
used", which is **false** for this film: the singing comes from a singing model. The custom
`--line2` says what is true.

### Assemble + gates (steps 17–18)
```bash
$PY tools/assemble.py --manifest manifest.json --vo vo --shots out/shots --loops loops --bursts bursts \
    --work out/segments --out out/voice-film.mp4 --intro out/brand/intro.mp4 --outro out/brand/outro.mp4
# segment map + joins, then verify (start the speech server for the content check, stop it after)
$PY $R/plugins/narrated-film/scripts/verify.py --film out/voice-film.mp4 --manifest manifest.json \
    --timeline out/voice-film.mp4.timeline.json --joins <from work/segments-map.json> --target-lufs -17 --tolerance 1.0 --base "$OMLX_BASE"
$PY tools/ab-equality.py     # each A/B half IS its own loop (control: the other half's loop)
$PY tools/film-motion.py     # every play beat moves; every one-still talk beat is static (+ self control)
./loud.sh out/voice-film.mp4
```
`tools/assemble.py` is a LOCAL FORK of the narrated-film assembler. It adds `playShots`, the
ported `normalize:false`, the timeline sidecar, and the true-peak backstop.

## Stop everything
`kill <launcherPid>` from `staging.json` stops staging pidfile-exact. Prove it with
`/bin/ps -axo pid,command > file` plus a grep for the pid, `lsof -nP -iTCP:17695 -sTCP:LISTEN`
(must be empty), and a positive control: `lsof … :17600` must still show the user's live app.
The singing sidecar (port 18004) is started and stopped by the app; check
`node ctl.mjs sing.sidecarStatus '{}'` before stopping staging. Never use pkill, pgrep or killall.

## Traps this folder paid for (each one is in the code where it bites)
- **A try/finally with `process.exit` swallows errors and exits 0.** Every script has a catch that sets `exitCode = 1`.
- **`-ss t1 -i F -ss t2 -i F … blend=difference` does not compare t1 with t2.** blend pairs by timestamp. It read 0 on a moving beat and 255 on a still. Motion is now checked by numpy on separately extracted frames (`tools/take-motion.py`, `tools/film-motion.py`).
- **`metadata=print` and the ebur128/astats summaries log at INFO.** Under `-loglevel error` / `-v error` they print nothing and exit 0. Use `-hide_banner`, or `file=`.
- **A 1 ms-grid cross-correlation lands on a pitch-period side lobe of a solo voice** (0.54 instead of 0.99). `ab-equality.py` searches every sample, by FFT.
- **AAC adds about 0.5 dB of true-peak overshoot on drums.** That left the film exactly at −1.00 dBTP, so the loops are cut at −2.0.
- **The note editor is a latch.** Selecting another (audio) clip clears it, which is how the arrange takes get a clean view.
- **The Voice tool's marks are drawn only while that tool is active.** The Voice A/B takes select it (`editor:14:voice`), or both halves show the same picture.
