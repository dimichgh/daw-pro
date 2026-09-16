# THE STACK

**Film** `out/stack.mp4` — 51.90 s, -13.9 LUFS
integrated, -1.0 dBTP, 10,077,661 bytes, LRA 5.8 LU,
1484 picture frames at 30 fps ( = round(music seconds x 30), asserted at build time).

**Key / tempo** A minor, 128 BPM, 25 bars.
**Concept** A drum kit alone; one more instrument every two bars until twelve are playing, then a tutti landing.
**Instruments** (all MuseScore General) Drum kit (kick + closed hats), fingered bass, snare + shaker, pizzicato strings, marimba, tine electric piano, choir, French horns, cello, glockenspiel, trumpet, taiko.
**Tracks** 12  **Notes** 809

## What changed from the brief, and why
**The kick does NOT open alone, and that is the deliberate change.** Measured on
the first cut: 83.9 % of the opening two seconds' energy sat below 120 Hz and
only 1.9 % above 300 Hz (controls: a 60 Hz sine reads 0.000 % above 300 Hz, a
2 kHz sine 100.000 %) — a phone speaker reproduces almost none of it, and the
brief asks for two seconds a viewer enjoys. The closed hat now enters with the
kick as ONE drum kit, which keeps the "one more instrument every two bars" rule
exactly, and the old bar-4 hi-hat entry became a snare-and-shaker layer.
Re-measured: 14.8 % above 300 Hz, 7.8x the first cut.

ELEVEN entries plus the landing, not twelve entries: twelve at two bars each is 24 bars before anything happens and does not fit in 55 s. The twelfth part arrives ON the tutti.

## Gates
- `verify.py`: 7 ok, 1 allowlisted BROKEN (content — a wordless film has no
  narrated stages, so the cross-stage control cannot exist).
- `lib/sync.py`: `[  ok  ] sync: 95.8% matched vs 4.7% wrong-phase control, offset +14.7 ms, drift 1.6 ms`
- Mix loudness the DAW measured before the bounce: see `out/loudness.json`.

## Build
    python3 song.py                                   # -> song.json
    node ../lib/build.mjs song.json out               # staging 17695
    node ../lib/gain.mjs  song.json out -14           # steer the master gain
    ../../../../plugins/narrated-film/.venv/bin/python ../lib/tunesmith.py 01-stack

Or the whole thing: `tunesmith.py 01-stack` (add `--skip-build` to reuse
`out/music.wav` and only re-cut the picture).
