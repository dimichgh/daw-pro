# THE CANON

**Film** `out/canon.mp4` — 49.10 s, -13.9 LUFS
integrated, -1.1 dBTP, 7.2 MB,
1400 picture frames at 30 fps ( = round(music seconds x 30), asserted at build time).

**Key / tempo** E major pentatonic, 116 BPM, 21 bars.
**Concept** One line, three voices, entering at beats 0, 8 and 20 — offsets of 8 and 4 against a 16-beat phrase, so no two voices ever line up.
**Instruments** (all MuseScore General) Marimba, vibraphone, celesta, pizzicato bass, bowed glass pad.
**Tracks** 5  **Notes** 471

## What changed from the brief, and why
PENTATONIC, so the entries could be chosen for the PICTURE (staggered, non-multiples of the phrase) instead of for the harmony. A canon has to consonate against a displaced copy of itself at every offset; in a scale with no semitone that is nearly free.

## Gates
- `verify.py`: 7 ok, 1 allowlisted BROKEN (content — a wordless film has no
  narrated stages, so the cross-stage control cannot exist).
- `lib/sync.py`: `[  ok  ] sync: 85.7% matched vs 3.8% wrong-phase control, offset +16.1 ms, drift 3.0 ms`
- Mix loudness the DAW measured before the bounce: see `out/loudness.json`.

## Build
    python3 song.py                                   # -> song.json
    node ../lib/build.mjs song.json out               # staging 17695
    node ../lib/gain.mjs  song.json out -14           # steer the master gain
    ../../../../plugins/narrated-film/.venv/bin/python ../lib/tunesmith.py 04-canon

Or the whole thing: `tunesmith.py 04-canon` (add `--skip-build` to reuse
`out/music.wav` and only re-cut the picture).
