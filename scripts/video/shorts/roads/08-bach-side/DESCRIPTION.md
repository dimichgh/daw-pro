# YouTube description block — paste as-is (THE SIDE-VIEW CUT)

⛔ UPLOAD AS A **PRIVATE DRAFT** ONLY, AND NOT BY US. Publishing, scheduling and
visibility are the user's actions in YouTube Studio. Nothing in this round was
uploaded anywhere.

---

## Title

    J. S. Bach — Prelude in C, BWV 846 (complete) · watched from the side

## Description (paste below the line)

---
The first prelude of The Well-Tempered Clavier, Book I — all thirty-five bars,
from the opening arpeggio to the fermata. Same performance as the main film,
seen from off the edge of the page instead of from behind.

The score IS the road. Time runs away from you down the page: each staff is a
lane, each note sits where it really sits on the stave, and the three lights are
the three voices Bach actually wrote — the broken-chord figure in the right hand,
and the two held voices underneath it that the left hand plays as one gesture.

This angle exists for one passage. At 1:32 the bass stops moving sideways and
holds a single low G for eight bars while everything above it keeps flowing —
thirty-two seconds of one unchanging note. From the side its road runs nearest
the camera, so that held note reads as a continuous bar of light rather than a
distant dot. It lands on C at 2:04. A bar later, at 2:08, the figure finally
breaks its own pattern, and it never returns to it: the last three bars are all
different.

Built and rendered end to end in DAW Pro — an AI-native DAW for macOS. The
performance, the mix, the loudness pass and the visualiser are all one pipeline;
nothing here was recorded from a screen.

—

SCORE / LICENCE
Visualisation inspired by Polyfjord — thank you for the idea.

Notes derived from the Mutopia Project edition Mutopia-2011/09/12-5, typeset by
Shay Rojansky, edited by Han-Wen Nienhuys and Tobias Erbsland.
The edition's own header dedicates it to the public domain.
Source: https://www.mutopiaproject.org/

The composition itself is in the public domain.

AUDIO
Rendered offline at 48 kHz, normalised to −14 LUFS integrated with a −1 dBTP
ceiling (the usual streaming convention).

CHAPTERS
0:00 Bars 1–10 — the figure, and the two voices under it
0:40 Bar 11 — the harmony moves off the opening
1:12 Bar 19 — the approach
1:32 Bars 24–31 — the pedal: the bass stops moving
2:04 Bar 32 — the bass lands on C
2:08 Bar 33 — the figure breaks its own pattern
2:16 Bar 35 — the final chord
---

## ⚠ Every number above is DERIVED. `derive.py` prints this table.

`python3 ../06-bach-prelude/derive.py .` reads THIS directory's `song.json` and
`out/payload.json`. **One deriver, shared with 06 and 07** — round 31 shipped a
wrong timestamp (bar 32 where the computation says bar 33) that was a number
typed into a copy of this file.

| moment | derived from | seconds | m:ss |
|---|---|---|---|
| the piece begins | bar 1 line; BOTH left-hand voices sound at beat 0 and the figure at beat 0.5 | 0.018 | 0:00 |
| the G2 pedal begins | longest run of ONE bass pitch: MIDI 43, 16 onsets from beat 92 | 92.017 | 1:32 |
| the G2 pedal ends | that run's LAST note SOUNDS to beat 124 (a sounding end, not an onset) | 124.017 | 2:04 |
| the pattern breaks | first bar whose figure half-bars DIFFER, computed: bar 33 of 35; halves IDENTICAL in 32 bars (1–32), DIFFERING only in 33, 34, 35 | 128.018 | 2:08 |
| the final chord | last figure onset, beat 136, 3 notes, 4 beats long | 136.018 | 2:16 |
| the last sound ends | max(start+length) over all three roads, beat 140 | 140.018 | 2:20 |
| the end card begins | song.json look.endCard.at | 141.400 | 2:21 |
| the film ends | last of 4476 rendered frames: (4476-1)/30 | 149.167 | 2:29 |

The music, the note data and the loudness pass are byte-for-byte the same
material as the main film — **verified, not asserted**: `06/out/music.wav` and
`08/out/music.wav` are both 54,685,696 B with md5
`0b24fec6ceb80e7c03712750a30f4308`, and the two `song.json` `tracks` arrays
compare equal. **Only the camera differs**, and it differs because
`BACH_CAM=side` selects a different shot list in the same `song.py`. The
post-prep payload pins it: `look.take = "journey"`, 7 segments, every one
`type: "side"` (06's same-named take mixes `quarter` and `side`).

## Why this cut, MEASURED

⚠ **This section said the opposite yesterday, and the correction is the finding.**
The reason offered for a side cut was that it keeps every road on screen where
the landscape cut does not. I ran `framing.mjs` at `FRAMING_ALLOW=0`, got
`0 out of 12,912 playhead-frames` on BOTH cuts, and wrote that the premise did
not discriminate. **The gate was blind.** It only counted playheads brighter
than `env > 0.25`, and a voice AT REST sits at `idleFloor` **0.13** — so every
resting playhead was invisible to it, and a rest is exactly when a road stops
being tracked and drifts off the edge. On `03-moonlight-long` the gate reported
0 of 24,324 while the Melody road is visibly unlit for eighteen seconds.

With the gate counting resting voices, on the Moonlight pair the premise is
**overwhelming** — 575 resting playhead-frames off screen at a visible
brightness on the landscape cut against **4** on the side cut. And the difference is bigger than the
lamp suggests: `env` drives the lamp, `envCore` drives the DISK, and at rest
under `coreSteady: 1` they diverge — the off-frame melody playhead measures env
0.130 but **envCore 0.600, the same disk brightness a sounding voice has**.

⭐ **The user has since ruled that this is NOT a defect.** Shown the landscape
frame with the Melody road dark, they said it "makes it more natural that camera
in 2nd image is looking to the right" and approved all three frames. So the
575-vs-4 gap is a measured DIFFERENCE BETWEEN TWO CUTS, not a fault in one of
them — it says what this angle does differently, and nothing here needs fixing. On THIS pair,
both Bach cuts measure **0**: nothing off screen that a viewer could see. So
the framing reason is real, it is just not what earns this particular cut.

What earns it here is how much of the frame the held note occupies. At the
mid-pedal instant (t = 108.000 s, frame 3240, the same frame in both films):

| | bright px ≥200 | as % of frame | largest single lamp | px ≥245 |
|---|---|---|---|---|
| 06, the landscape journey | 5,711 | 0.28 % | 1,688 | **18** |
| 08, this side cut | **13,976** | **0.67 %** | **7,378** | **1,576** |

2.4× the lit area, 4.4× the largest lamp, and the side cut is the only one of the
two with any core-white pixels at all at that instant.

One more difference worth stating: the seam gate's pixel probe (S3) returns a
real verdict on this cut and reports BROKEN on the landscape one, because from
the side 0.5 world units along the road covers enough pixels to sample.

## ⚠ AN ONSET COUNT IS NOT A SOUNDING COUNT

    t= 93.017s  sounding: Figure 1  Tenor 1  Bass 1
    t=108.017s  sounding: Figure 0  Tenor 1  Bass 1
    t=123.017s  sounding: Figure 1  Tenor 1  Bass 1
    t=132.018s  sounding: Figure 0  Tenor 1  Bass 1

The two zeros are CORRECT: every bar of the figure begins with a written eighth
rest (`r8`), so at a bar line the figure genuinely is not sounding.

## ⚠ Two caveats on the licence, carried across deliberately

1. The public-domain statement is the **typesetter's dedication written inside the
   `.ly` file** (`copyright = "Public Domain"`). It is a statement in a source
   file, not a licence document, and it is quoted rather than interpreted.
2. That header's own `source` field reads **"Unknown"** — the edition this was
   keyed from is not stated. The COMPOSITION is unambiguously public domain; the
   ENGRAVING's provenance rests on the dedication above.

This is a different licence from the Moonlight films, which carry CC BY-SA 2.5
and its share-alike obligation. This one does not.

## Loudness, off the FINISHED MUX

`ffmpeg -hide_banner -i out/bach-side.mp4 -af ebur128=peak=true -f null -`:
integrated **−14.0 LUFS**, true peak **−1.2 dBFS**, LRA **2.1 LU**.
Read off the mux, not off the intermediate `music.wav`.
