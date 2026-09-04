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
