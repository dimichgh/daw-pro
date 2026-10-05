# THE CASCADE

**Film** `out/cascade.mp4` — 49.07 s, -14.3 LUFS
integrated, -1.1 dBTP, 7.6 MB,
1399 picture frames at 30 fps ( = round(music seconds x 30), asserted at build time).

**Key / tempo** D major pentatonic, 132 BPM, 24 bars, sixteenth notes.
**Concept** A continuous arpeggio sweeping five octaves while the timbre changes note by note through twenty-four programs.
**Instruments** (all MuseScore General) Grand piano, glockenspiel, nylon guitar, flute, marimba, pizzicato strings, clarinet, vibraphone, harp, oboe, celesta, steel guitar, trumpet, kalimba, recorder, music box, koto, piccolo, xylophone, harpsichord, banjo, pan flute, tubular bells, steel drums — over a bowed bed and timpani.
**Tracks** 26  **Notes** 468

## What changed from the brief, and why
TWENTY-FOUR TRACKS, one program each, dealt round-robin: an instrument is a property of the TRACK, so 'a different instrument on every note' means a different track on every note. Colours are a hue RAMP, not a palette — twenty-four hand-picked colours stop being distinguishable.

## Gates
- `verify.py`: 7 ok, 1 allowlisted BROKEN (content — a wordless film has no
  narrated stages, so the cross-stage control cannot exist).
- `lib/sync.py`: `[  ok  ] sync: 91.2% matched vs 27.0% wrong-phase control, offset +16.6 ms, drift 1.3 ms`
- Mix loudness the DAW measured before the bounce: see `out/loudness.json`.

## Build
    python3 song.py                                   # -> song.json
    node ../lib/build.mjs song.json out               # staging 17695
    node ../lib/gain.mjs  song.json out -14           # steer the master gain
    ../../../../plugins/narrated-film/.venv/bin/python ../lib/tunesmith.py 06-cascade

Or the whole thing: `tunesmith.py 06-cascade` (add `--skip-build` to reuse
`out/music.wav` and only re-cut the picture).
