# Session film — "Four Waveforms"

**The claim:** every sound in this session comes from `saw`, `square`,
`triangle`, `sine` — the entire palette DAW Pro's poly synth offers. No sample
is loaded, no recording is used, no generation model is called. Verifiable,
because the whole session is driven over the control protocol and every number
is measured off the render.

**Why this is the right claim:** the synth genuinely has no noise oscillator
(`waveform must be one of saw|square|triangle|sine` — measured, with a bogus
control refused). That constraint is the film.

## Chapters

| # | Chapter | The "huh" | Status |
|---|---|---|---|
| 1 | Cold open — siren, heartbeat, thunder, a voice | none of it is a recording | material built |
| 2 | The instrument, and how it is being driven | the DAW itself was written by AI; every move here is a JSON command | — |
| 3 | The siren | one note. The pitch does everything. | ✅ 3.97 semitones measured vs 4.00 asked |
| 4 | The heartbeat | 94% of it is below 60 Hz — you feel it more than hear it | ✅ measured |
| 5 | Thunder | thunder is not a pitch, it is a filter closing | building |
| 6 | The 808 | the most famous bass in music is a sine somebody ruined | pending |
| 7 | **Rain — the one that failed** | measured 157× better and still 36× short | ✅ measured |
| 8 | A voice with no voice | two resonances are a vowel | pending |
| 9 | The effects tour | stock tools only | pending |
| 10 | DJ looping | layers built live | pending |
| 11 | Arrange | — | pending |
| 12 | Mix + master, measured | — | pending |
| 13 | The honest chapter | what I can and cannot judge | pending |

## Measured so far

- Waveforms available: `saw square triangle sine`; `noise` and `pulse` REFUSED.
- Siren: fundamental 393.4–494.8 Hz = **3.97 semitones** (the pitch-bend lane
  asks for 4.00); 8 wails in 8 s at 120 bpm, as written.
- Heartbeat: **94.0%** of energy below 60 Hz, 5.8% 60–120 Hz, 0.2% above 120 Hz.
  20 notes written (a 25 %-threshold detector finds 17 — the soft "dub" at
  velocity 88 sits under it; the number on screen must be the 20 that were
  WRITTEN, not the 17 a threshold happened to catch).
- Rain: spectral flatness **0.0001** (896 blips) → **0.0157** (3520 short
  grains). White noise measures **0.5615**; a single sine measures **0.0000**.
  So the mechanism is real and directional, and still 36× short.

## Rules carried from the lesson wave

- A non-musical demo sound must not bed under narration (`bedEligible: false`).
- Every figure on screen is measured, computed or cited.
- Nothing generated gets committed; tools and specs only.

## What shipped

Seven videos, all built from the one session and the one `MEASUREMENTS.json`.
The film and the Shorts quote the same figures because they read the same file
— a number is never typed twice, so the two can never disagree.

| File | Length | Argument |
|---|---|---|
| `DAW Pro Session - Four Waveforms.mp4` | 406.7 s | the whole build, start to finish |
| `DAW Pro Short 13 - One Note Siren.mp4` | 30.2 s | a siren is one held note; the bend does the moving |
| `DAW Pro Short 14 - Heartbeat Under 60Hz.mp4` | 28.9 s | 94 % below 60 Hz, so a phone plays none of it |
| `DAW Pro Short 15 - The 808 Is A Sine.mp4` | 43.7 s | drive adds above the fundamental, never below |
| `DAW Pro Short 16 - A Vowel Is Two Numbers.mp4` | 29.9 s | F1/F2 on a saw and it says *ah* |
| `DAW Pro Short 17 - I Failed To Make Rain.mp4` | 38.8 s | the chapter that did not work, with its numbers |
| `DAW Pro Short 18 - Thunder Is A Filter.mp4` | 32.4 s | a centroid collapsing, with the lane-off control |

⚠️ **The Shorts' content gate reports `[BROKEN]`, and that is the gate working.**
It refuses to score a transcript-vs-script separation on two stages under 45 s,
because with that little material the cross-stage control cannot mean anything.
A gate that declined to score is not a gate that passed — the Shorts' words are
covered instead by the per-stage `factCheck` assertions, which all passed.

## The zoom bug, and why every gate missed it

The film shipped once with `04-siren`'s zoom framing **empty timeline** below the
synth panel. All eight verify gates passed: `distinct frames` is perfectly happy
with two different views of nothing, and no gate in this rig has any idea *where*
a crop lands. The same pass found the saturator panel reading `30.0 dB` while the
narration says "thirty two decibels" — the figure the sweep was actually measured
at, so the panel was re-shot rather than the sentence re-worded.

**The check that found both takes three minutes** and belongs in every session:
render each `zoom` rect as a still and look at it.

```sh
ffmpeg -y -i shots/<name>.png \
  -vf "crop=iw*<w>:ih*<h>:iw*<x>:ih*<y>,scale=860:-1" -frames:v 1 /tmp/check.png
```

## And three card bugs under it

The same frame that exposed the zoom showed the card behind it reading **"E
SIREN, MEASUR"**. Three separate faults, none of which any gate can see:

1. `sp()` joined letters with three literal spaces while the renderer *also*
   letter-spaces with `track=`. Every label was three times its intended width,
   so the auto-fit shrank it to 12–24 pt. Legible, and clearly wrong.
2. `card_bignumber` had no fit on `label` or `unit` at all — `card_list`'s title
   had been fixed for exactly this and the big-number card had not — so a label
   that overflowed was simply sliced at both ends.
3. A `list` card's left key had no column bound and drew through its own value.

Fixed in the renderer, so the next spec cannot hit them; and the spec's own keys
were shortened so nothing has to shrink in the first place.
