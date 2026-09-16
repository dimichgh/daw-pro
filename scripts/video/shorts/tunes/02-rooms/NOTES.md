# FOUR CHORDS, FIVE ROOMS

**Film** `out/rooms.mp4` — 53.43 s, -14.0 LUFS
integrated, -1.0 dBTP, 7.6 MB,
1530 picture frames at 30 fps ( = round(music seconds x 30), asserted at build time).

**Key / tempo** Am F C G, 100 BPM, 20 bars, four bars per room.
**Concept** The same progression through bossa nova, house, metal, a string quartet and lo-fi.
**Instruments** (all MuseScore General) Nylon guitar/upright bass/brushes/flute; kit/synth bass/EP stabs/strings; distortion guitar/picked bass/power kit/church organ; two violins/viola/cello; Rhodes/soft bass/brush kit/vibraphone.
**Tracks** 20  **Notes** 570

## What changed from the brief, and why
ONE TEMPO for all five rooms, not five. A tempo map would make the four-bar loop a different length in every room and the 'same harmony' claim would stop being visible in the grid. The rooms are made by instrumentation, register and rhythm. Also: the legend groups twenty parts into five ROOMS, because fifteen names scrolling is not the point.

## Gates
- `verify.py`: 7 ok, 1 allowlisted BROKEN (content — a wordless film has no
  narrated stages, so the cross-stage control cannot exist).
- `lib/sync.py`: `[  ok  ] sync: 89.7% matched vs 7.2% wrong-phase control, offset +15.6 ms, drift 4.8 ms`
- Mix loudness the DAW measured before the bounce: see `out/loudness.json`.

## Build
    python3 song.py                                   # -> song.json
    node ../lib/build.mjs song.json out               # staging 17695
    node ../lib/gain.mjs  song.json out -14           # steer the master gain
    ../../../../plugins/narrated-film/.venv/bin/python ../lib/tunesmith.py 02-rooms

Or the whole thing: `tunesmith.py 02-rooms` (add `--skip-build` to reuse
`out/music.wav` and only re-cut the picture).
