# Session films — driving DAW Pro to build a track on camera

These are the scripts behind *Four Waveforms*: a whole track written into DAW
Pro over the control protocol, photographed as it is built, and narrated with
numbers measured off the renders.

Nothing here generates music with a model. Every sound is written as notes and
shaped with the app's own synth, filter, envelope and effects.

## The rule that shapes everything else

The built-in poly synth accepts exactly four waveforms:

```
waveform must be one of saw|square|triangle|sine
```

`noise` and `pulse` are refused (measured, with a bogus value refused the same
way as a control). So there is no noise oscillator, and no sample is loaded —
rain, thunder, a siren and a singing vowel all have to come out of those four.

## Layout

| File | What it does |
|---|---|
| `build.mjs` | the shared wire helpers: one socket, `cmd`, `shot`, `addTrack`, `addClip`, a seeded RNG |
| `sounds.mjs` | one chapter's sound per run — siren, heartbeat, thunder, 808, vowels — each in a fresh project, rendered solo |
| `thunder2.mjs` | thunder take 2, **with the automation-off control render** |
| `sat.mjs` | the saturator sweep: same note at 0 / 14 / 32 dB of drive |
| `track.mjs` | the whole 64-bar arrangement, 8 tracks, ~1,300 notes |
| `loops.mjs` | the DJ chapter: one 4-bar loop rendered five times with layers arriving |
| `fixvoice.mjs` | raises the vocal hook and re-renders (it was arriving at +0.5 dB) |
| `capture.mjs` | photographs the session — arrange, synth editors, effect editors, mixer |
| `satshot.mjs` | re-shoots the saturator panel at the **32 dB the narration names** (`fx-saturator-32.png`) |
| `sweepshot.mjs` | a control BEING MOVED: waveform buttons, the filter closing, drive 0/14/32, the vowel peaks walking |
| `pianoshot.mjs` | the piano roll, via `debug.captureUI {selectClip}` |
| `hithere.mjs` | the words chapter: two EQ peaks on automation lanes, walked along a vowel path |
| `subshot.mjs` | shoots the 808's poly synth on SINE (`synth-808-sine.png`) — the A/B's honest "before" |
| `spec.py` / `shorts.py` | emit the film and Shorts specs for `shortsmith.py` |
| `../meter.py` | burns a live 16-band spectrum meter into a corner of a finished film, driven by the film's OWN audio (`"meter": "br"` in a spec turns it on) |
| `MEASUREMENTS.json` | every number the narration says, written by the measuring steps |

## Running them

```sh
export DAW_CONTROL_PORT=17695        # NEVER 17600 — that is the user's live app
export DAW_TIMEOUT_MS=900000         # a 2-minute render outlasts the 30 s default
export SESSION_DIR=$PWD/out SESSION_AUDIO=$PWD/out/audio SESSION_SHOTS=$PWD/out/shots
node build.mjs                       # (library — imported by the others)
node sounds.mjs siren                # then heart, thunder, bass808, vowel
node track.mjs && node loops.mjs && node capture.mjs
python3 spec.py && python3 shorts.py
```

`build.mjs` refuses to run against port 17600 outright.

`satshot.mjs` and `subshot.mjs` each shoot ONE panel and are run the same way,
with one addition — give them an isolated profile so no recovery sheet can draw
itself across the panel:

```sh
DAWPRO_PROFILE_ROOT=$PWD/out/profile DAW_CONTROL_PORT=17695 node subshot.mjs
```

## Tooling — what is installed, and what each is FOR

| Tool | State | Use it for |
|---|---|---|
| `debug.captureUI` / `view.capture` | shipped | ⭐ **THE DEFAULT FOR EVERYTHING.** Headless — no window need be on screen, no permission, does not disturb the user. **They named this as a feature they like; do not migrate away from it for convenience.** |
| ScreenCaptureKit recorder (`scripts/video/screenrec/`) | ✅ **BUILT 2026-09-05**, permission verified granted; 150 frames in 5.0 s at 30 fps, motion proven against a static control | **MOTION ONLY** — a terminal scrolling, a drag, a control actually moving, the "I can dance" film. `debug.captureUI` runs at ~3.5 fps (measured; `scale` does not change it) and cannot film movement at all. |
| `manim` 0.21.0 | installed 2026-09-05 | Animated diagrams: a transfer curve bending as the knee widens, an envelope recovering, a spectrum sliding. The right tool for a channel about curves and numbers. ⚠️ Needed `brew install pkg-config cairo pango` first — pip alone fails at `pycairo`'s meson step. Homebrew is needed at BUILD time only; renders fine without `/opt/homebrew/bin` on `PATH` (verified). |
| `matplotlib` 3.11.1 | installed 2026-09-05 | Measurement plots. ⚠️ It failed the first time only because it shared a `pip install` line with `manim`, whose metadata failure aborted the whole resolve — **a collateral failure that looked like its own.** |
| ffmpeg `zoompan` / `xfade` / `scroll` | ALREADY THERE, still unused | Slow pushes on stills and real chapter transitions, for free. ⭐ **Reach for these BEFORE asking for an install.** |
| ffmpeg `drawtext` | ⛔ ABSENT (no freetype in this build) | Nothing — this is why every card's text is rendered through PIL. |

## Things that cost a build each

- **The wire and the MCP tool disagree.** `clip.addMIDI` takes `atBeat`, not
  `startBeat`, and has no `returnNotes`. `transport.seek` takes `beats`, not
  `beat`. Instrument parameters are FLAT (`waveform`, `cutoffHz`), not nested
  under `polySynth`. Sending the MCP shape is refused, which is the good case.
- **Pitch-bend lane points are raw 14-bit MIDI**, 0–16383 with 8192 as centre —
  not the −1…+1 the name suggests. A normalised value is refused.
- **`debug.*` varies by build.** This one has `captureUI` and `panelLayout` but
  not `selectClip`, and an unknown command is a hard error that killed the
  capture run twice. Every optional step in `capture.mjs` is wrapped, and what
  it skipped is printed — a hole in the film, not a silent success.
- **The client's reply timeout is 30 s.** A two-minute render blows through it
  and reports `no reply in 30000ms` while the app is still working perfectly.
- **Never run two of these at once.** They each call `project.new`; a second
  script mid-flight wipes the first one's work.
- **RMS is the wrong instrument for a hi-hat.** The hats layer measured +0.0 dB
  of RMS and +7.6 dB in 2–16 kHz. Measure a layer in the band it occupies.
- **A flat filter sweep and a dead automation lane look identical.** Thunder
  take 1 barely moved because a low cluster has nothing up top for a lowpass to
  remove. The only way to tell them apart was rendering again with the lane
  disabled — which is why `thunder2.mjs` always writes both.
- **One `--out-dir` per spec, always.** Narration takes are named for their
  STAGE id, so a film and a Short that both have a stage called `01-hook` share
  `vo/01-hook.wav`. Building them into one directory let a Short's opening line
  end up inside the film on the next `--skip-narrate` rebuild, and all eight
  gates passed it. `shortsmith.py` now refuses that case rather than assembling
  it, but separate directories are the actual fix.
- **A stage's words-per-minute is the cheapest lie detector in the rig.** Every
  take in this film sits between 226 and 266 wpm. Anything far outside that is
  the wrong audio or a truncated one, and no other gate will say so.
- **Verify a shipped video by TRANSCRIBING IT, not by trusting the cache.**
  `_cache.json` records who last *recorded* a take, which is not the same as who
  last *used* one — `--skip-narrate` never writes to it. The six Shorts here
  were cleared by extracting their audio and running `shortsmith.transcribe()`
  over it: all six say their own script, every `factCheck` hits.
- **A panel on screen must be a panel DOING something.** `sweepshot.mjs` steps a
  parameter and photographs each value; `shortsmith` cycles a stage's shots at
  its `cut`, so N stills at a short cut IS the animation, and every frame is the
  real app with the real number on it.
- **`debug.captureUI` runs at 3.5 fps and `scale` does not change that** (277 /
  282 / 284 ms per frame at scale 2 / 1.5 / 1 — the cost is the window render).
  That is the ceiling on motion in these films.
- **`debug.selectClip` does not exist; `debug.captureUI {selectClip}` does.**
  Calling the non-existent name is how the first cut shipped with no shot of the
  piano roll at all — the wrapper printed "skipped" into a log nobody read.
- **Shoot with `DAWPRO_PROFILE_ROOT` set.** It moves autosave/recovery/settings
  to a scratch dir, so no "Restore unsaved work?" sheet can draw itself across
  the panel you are photographing.
- **A demo segment should show the app PLAYING it.** `burst()` in `build.mjs`
  opens the piano roll, starts the transport and photographs the app until the
  sound ends; `assemble.py` builds the play segment from those frames at the
  rate `meta.json` records. Pass `{arrange: true}` for multi-track material —
  one clip's roll scrolled to bar 1 while the playhead is at bar 36 is an empty
  grid.
- ⚠ **Set the master to zero first.** A burst plays through the machine's real
  output device.
- **The roll opens on an EMPTY GRID for a low clip, and no amount of zoom fixes
  it.** It anchors high in the 128-row pitch stack, so a 49 Hz heartbeat at C1
  draws in the minimap and the velocity lane and nowhere else. MEASURED at the
  10 pt row-height floor (the clamp — a request for 5 lands there): the grid still bottomed out at F2 with the notes
  below it. `debug.panelLayout {pianoRollCenterPitch}` scrolls the pitch axis;
  `burst()` sends the clip's own MEDIAN pitch, so no chapter is special-cased.
  ⚠ ORDER MATTERS: open the roll first (the scroller has to exist), and send the
  focus AFTER any row-height change (that re-pins the axis and undoes it).
  The product half of this — auto-centring when a roll OPENS — is roadmap m35-h.
- **A re-shoot must CLEAR the burst directory first.** It writes `f0001..fN` and
  stops; the previous take's frames past N survive and `assemble.py` globs the
  directory, so a shorter re-shoot silently ends on frames it was meant to
  replace. Caught by counting files against `meta.json` — 25 on disk, 18 in
  meta. `build.mjs` now clears; the CHECK is still worth running.
- **`spec.py` resolves `shots/` and `audio/` from ITS OWN directory**, not from
  `SESSION_SHOTS`/`SESSION_AUDIO` (those are read by the node capture scripts
  only). Run the copy that sits beside the assets, or every path in the emitted
  spec points at an empty repo directory and the build dies on the first
  `ffprobe`.
