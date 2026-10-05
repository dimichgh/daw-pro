# ONE LINE, TWELVE COLOURS

**Film** `out/colours.mp4` — 54.37 s, -13.9 LUFS
integrated, -1.2 dBTP, 7.1 MB,
1558 picture frames at 30 fps ( = round(music seconds x 30), asserted at build time).

**Key / tempo** D major, 126 BPM, 24 bars, an eight-beat phrase twelve times.
**Concept** One melody re-orchestrated every two bars; the notes are literally the same clip material every time.
**Instruments** (all MuseScore General) Grand piano, nylon guitar, marimba, flute, trumpet, violin, church organ, clarinet, vibraphone, steel drums, choir, square lead — over a constant bass and kit.
**Tracks** 14  **Notes** 508

## What changed from the brief, and why
TWO BARS per colour, not four: twelve four-bar statements is 110 s. The claim is checked by lib/identity.py against the notes read BACK out of the DAW, and that check is run with a note deliberately mutated to watch it fail.

## Gates
- `verify.py`: 7 ok, 1 allowlisted BROKEN (content — a wordless film has no
  narrated stages, so the cross-stage control cannot exist).
- `lib/sync.py`: `[  ok  ] sync: 89.8% matched vs 20.9% wrong-phase control, offset +16.0 ms, drift 1.4 ms`
- Mix loudness the DAW measured before the bounce: see `out/loudness.json`.

## Build
    python3 song.py                                   # -> song.json
    node ../lib/build.mjs song.json out               # staging 17695
    node ../lib/gain.mjs  song.json out -14           # steer the master gain
    ../../../../plugins/narrated-film/.venv/bin/python ../lib/tunesmith.py 03-colours

Or the whole thing: `tunesmith.py 03-colours` (add `--skip-build` to reuse
`out/music.wav` and only re-cut the picture).
