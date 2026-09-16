# ACCELERANDO

**Film** `out/accel.mp4` — 42.30 s, -14.2 LUFS
integrated, -1.1 dBTP, 7.1 MB,
1196 picture frames at 30 fps ( = round(music seconds x 30), asserted at build time).

**Key / tempo** E minor, 60 to 180 BPM over 64 beats, then six beats held.
**Concept** One bar-long riff, a real tempo map of 65 {startBeat,bpm} segments, and the beat grid visibly squeezing.
**Instruments** (all MuseScore General) Overdrive guitar, synth bass, power kit, brass stabs, timpani.
**Tracks** 5  **Notes** 566

## What changed from the brief, and why
A REAL TEMPO MAP, never a time-stretch. viz.py's Timing and DAWCore's TempoMap are both piecewise-CONSTANT over the same segments, so a beat line and the note under it come from the same arithmetic. Measured drift across the piece: 0.6 ms.

## Gates
- `verify.py`: 7 ok, 1 allowlisted BROKEN (content — a wordless film has no
  narrated stages, so the cross-stage control cannot exist).
- `lib/sync.py`: `[  ok  ] sync: 57.1% matched vs 6.5% wrong-phase control, offset +19.0 ms, drift 0.6 ms`
- Mix loudness the DAW measured before the bounce: see `out/loudness.json`.

## Build
    python3 song.py                                   # -> song.json
    node ../lib/build.mjs song.json out               # staging 17695
    node ../lib/gain.mjs  song.json out -14           # steer the master gain
    ../../../../plugins/narrated-film/.venv/bin/python ../lib/tunesmith.py 05-accel

Or the whole thing: `tunesmith.py 05-accel` (add `--skip-build` to reuse
`out/music.wav` and only re-cut the picture).
