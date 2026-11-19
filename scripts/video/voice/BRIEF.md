# Voice film brief: "What's new: tune a voice, sing your words" (orchestrator, 2026-10-10)

The user asked: *"given the current feature set with latest voice tuning, can you use video production skills
to create a demo of the new features, similar to the ones you uploaded to the youtube."*

You are the BUILDER. An independent `film-observer` verifies after you; a builder cannot verify its own work.
This folder (`scripts/video/voice/`) is the ONE home for every script, take, still, narration and the film.
Nothing the film needs may live in a session scratchpad (they are wiped after ~4 idle days, and a
session-scoped path is a deliverable with an expiry date nobody printed). Resolve the base from the script
(`VOICE_HOME`, defaulting to the script's own directory), exactly as `../features/` does with `FEATURES_HOME`.

## Read first, in this order (do not re-derive what they already pay for)
1. `plugins/narrated-film/skills/narrated-film/SKILL.md` (§ THE HOUSE STANDARD FOR A LESSON applies).
2. `claude-plugin/skills/demo-film/SKILL.md` and `claude-plugin/skills/ui-capture/SKILL.md`.
3. `scripts/video/features/README.md`, `DELIVERABLES.md`, `make-film.sh`, `manifest.json`, `start-staging.mjs`,
   `record-motion.mjs`, `record-all.sh` — the most recent released film of this kind (5:07). Copy its SHAPE.
4. `scripts/video/screenrec/README.md`.
5. The memory file `~/.claude/projects/-Users-dsemenov-Views-daw-pro/memory/daw-pro-video-pipeline.md`,
   lines 1–340 and 804–833 (every trap there was paid for by a real failure).

## ⭐ USER DIRECTION 2026-10-11 (verbatim): "do not use twinke or row your bot song, create a modern style song and create lead melody and then appy lyrics to the lead track notes"
No nursery or children's tunes anywhere (Twinkle, Row Your Boat, or test-fixture tunes). Compose an ORIGINAL
modern-style song in the app (own drum machine, bass, chords/pad), write an ORIGINAL lead melody on a lead track,
then apply ORIGINAL lyrics to that lead track's notes and have the built-in singer sing them. That build order
(song → lead melody → lyrics onto the lead notes → sung vocal) is itself the opening chapter; the tuning
chapters then work on that vocal.

## Content (~5 min, written for a NOVICE — the user is not a musician)
Centre on voice tuning. Features since the last features film (CHANGELOG.md sections 2026-09-23 → Unreleased):
1. **Sing your own words on a melody** (Unreleased item 10): a melody clip + lyrics → a sung vocal by the
   built-in singer. Show the Sing sheet as it reads TODAY — its key suggestion and harmony lines were changed
   this week; quote what the app shows now, never design-doc text. A harmony part ("a third above") is a good
   musical moment.
2. **The note editor on a voice**: hear the note you're editing, select and move several notes, the cut line
   (2026-09-25).
3. **Tune to Melody** (Unreleased item 1): make the take honestly sour ON CAMERA — pull a few notes off with the
   editor and SAY it was done on purpose — then Tune to Melody brings them back. A/B.
4. **Hard Tune vs natural tuning** (2026-09-24 / 09-27; Hard Tune's corrected description, Unreleased item 5:
   "Holds each note in tune, with less vibrato. The robot effect."), and **natural tuning keeps a low voice's
   size** + the Voice tool. A/B pairs.
5. Optional, if time and quality allow: a sung phrase becomes notes (2026-09-24); start a song from a band
   template (item 9); the drum machine's step grid (8 named rows + the new Accent row) and kit-sorted slicing.
   Cut these before cutting any explanation of 1–4.

⛔ EXCLUDE: the **Air (breathiness)** control — the user ruled on 2026-10-07 that every Air setting sounds like
static; keep Air at zero and never show it raised. ⛔ No effect-parameter automation lane on screen (the lane
editor draws only volume and pan — a known product gap; memory has the section).

**Vocal source: the built-in singer.** Do NOT use `~/Downloads/raw-raw-song.m4a` or any recording of the user's
own voice — that is the user's decision for a public video and has not been given.

## How (named, not described)
- Staging only: `DAW_CONTROL_PORT=17695`, set IN-PROCESS (features/README's hoisting trap), `DAW_TIMEOUT_MS`
  raised in-process for renders. ⛔ **Port 17600 is the user's LIVE app and it IS RUNNING right now
  (pid 31025, `dist/DAWPro.app`)** — never connect to it, never quit it, never use any `mcp__*daw-pro*` tool or
  the `demo-director` agent (they bridge to 17600). Launch staging with a parking launcher like
  `features/start-staging.mjs` (its own pidfile, its own profile root); stop it pidfile-exact.
- Create and NAME your own project in staging (e.g. "Voice Film 2026-10-10").
- Silence: route STAGING's output to BlackHole 2ch BY UID (`output.setDevice {uid}`; selected field is
  `isSelected`); keep the master at unity. Never change the system default output or the user's devices
  (ZoomAudioDevice, ParrotAudioPlugin).
- The singing engine: census how staging reaches it (the X9 lanes ran the real engine on a private port,
  127.0.0.1:18004). Use a PRIVATE port; never touch a sidecar the user's live app owns. Kill every sidecar you
  start pid-exact when it is no longer needed and confirm with `ps` + a positive control.
- Stills: `debug.captureUI` / `view.capture` is the DEFAULT (the user's stated preference: no app on screen).
  The screen recorder (`scripts/video/screenrec/`) ONLY for stages whose subject is MOTION (a playhead moving
  over notes, a drag). Rebuild with `--no-shots` before recording (editor cards cannot be closed). Verify every
  take MOVES (freezedetect + frame hashes, with a static control). Every stage its own burst dir and its own
  audio slice — `assemble.py` refuses duplicates; do not work around it.
- Narration: the ONE cloned voice. `eval "$(claude-plugin/skills/demo-film/scripts/speech-server.sh start)"` →
  `OMLX_BASE`; the binary is the in-repo `plugins/narrated-film/.venv/bin/omlx`; NEVER port 8000; ALWAYS
  `speech-server.sh stop` after. Never substitute another voice; if it will not start, STOP and report.
  Transcribe-and-compare every line (word lists, `autojunk=False`).
- Cuts on sentences: `cutOn` indices, never an even timer.
- Branding: `brand.py intro|outro` + `assemble.py --intro/--outro --brand <claude-plugin/skills/demo-film/brand.json>`.
  The cheap check: `out/intro.mp4` + `out/outro.mp4` exist and the cards do not read "YOUR BRAND". The
  synthetic-voice disclaimer only where narration exists.
- Python with Pillow: `plugins/narrated-film/.venv/bin/python` (system python3 has no PIL).
- Every number spoken or shown is MEASURED off the render that plays under it. Every A/B pair goes through
  `verify.py`'s `check_ab_separation`. Audibility: check each demonstrated difference can be heard on a laptop
  speaker; if not, say so on screen or show it another way (house standard).
- Loudness: the film near −16…−18 LUFS, true peak ≤ −1 dBTP, measured with `-hide_banner` (never `-v error`).
- Never run ffmpeg analysis beside a render; never pipe a render through `head`/`tail`.

## Standing constraints (non-negotiable)
No commits. Never `git checkout/stash/restore/clean/reset`. Never touch `.env`, `scripts/ace-step/`,
`scripts/rvc/`, or other waves' outputs under `scripts/video/`. Never pkill/pgrep/killall — pid/pidfile-exact
only. No `timeout(1)` on this machine. Never pair `2>/dev/null` with an emptiness you interpret. Grep
`scripts/` only with `--exclude-dir=video --exclude-dir=ace-step --exclude-dir=rvc --exclude-dir=node_modules`
(or name the files). Do not upload anything anywhere. Product development is PAUSED: if filming finds a product
defect, FILE it in your report (with how you saw it), do not fix product code. Do not edit `Sources/`.

## Deliverables (report each with its path)
- `scripts/video/voice/out/voice-film.mp4` (+ its `.timeline.json`), intro/outro, the narration takes,
  `manifest.json`, the build scripts, `README.md` (how to rebuild), `DELIVERABLES.md` (what is final).
- A LOOK report: for every capture of the Sing sheet, the note editor, the step grid/Accent row, say what it
  ACTUALLY shows (these are first looks at several owed UI halves) and anything that looks wrong.
- Gate results: content gate per line, freeze/motion, A/B separation, loudness/true peak, intro/outro present.
- Draft YouTube metadata (title, description, chapters) in `publish/` — NOT uploaded.
- Every process you started is stopped (staging, singing sidecar, speech server), shown with `ps` + a control.
