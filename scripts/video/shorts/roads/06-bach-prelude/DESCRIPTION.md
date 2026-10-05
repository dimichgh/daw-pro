# YouTube description block — paste as-is

⛔ UPLOAD AS A **PRIVATE DRAFT** ONLY, AND NOT BY US. Publishing, scheduling and
visibility are the user's actions in YouTube Studio. Nothing in this round was
uploaded anywhere.

---

## Title

    J. S. Bach — Prelude in C, BWV 846 (complete) · a road of light

## Description (paste below the line)

---
The first prelude of The Well-Tempered Clavier, Book I — all thirty-five bars,
from the opening arpeggio to the fermata.

The score IS the road. Time runs away from you down the page: each staff is a
lane, each note sits where it really sits on the stave, and the three lights are
the three voices Bach actually wrote — the broken-chord figure in the right hand,
and the two held voices underneath it that the left hand plays as one gesture.

Almost nothing about this piece changes. The figure is twelve sixteenth-notes a
bar — one six-note shape played twice — and in thirty-two of the thirty-five bars
the second half is note for note identical to the first. Only the harmony moves.
So watch the two quiet lights on the right instead. At 1:32 the lower one stops moving
sideways altogether and holds a single low G for eight bars while everything else
keeps flowing — thirty-two seconds of one unchanging note. It lands on C at 2:04.
A bar later, at 2:08, the figure finally breaks its own pattern, and it never
returns to it: the last three bars are all different.

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

`python3 derive.py` reads `song.json` and `out/payload.json` and re-derives all of
it; nothing here was typed from memory or from the score.

| moment | derived from | seconds | m:ss |
|---|---|---|---|
| the piece begins | bar 1 line; BOTH left-hand voices sound at beat 0 and the figure at beat 0.5 | 0.018 | 0:00 |
| bar 11 | bar line, `(11-1)*4` beats at ♩=60 + the 17.5 ms lag | 40.017 | 0:40 |
| bar 19 | same | 72.017 | 1:12 |
| the G2 pedal begins | the longest run of ONE bass pitch in the payload: MIDI 43 (G2), 16 onsets from beat 92 | 92.017 | 1:32 |
| the G2 pedal ends | that run's LAST note SOUNDS to beat 124 — a sounding end, not an onset | 124.017 | 2:04 |
| the pattern breaks | first bar whose figure half-bars DIFFER, computed by `derive.py` rather than typed: bar 33 of 35; the halves are IDENTICAL in 32 bars (1–32) and DIFFER only in 33, 34, 35 | 128.018 | 2:08 |
| the figure's density | 12 notes in 32 bars, 14 in two, 3 in the last (the final chord is one onset) — ⚠ round 29 quoted "16", which was BOTH HANDS | — | — |
| the final chord | last figure onset, beat 136, 3 notes, 4 beats long | 136.018 | 2:16 |
| the last sound ends | max(start + length) over all three roads, beat 140 | 140.018 | 2:20 |

⭐ **AN ONSET COUNT IS NOT A SOUNDING COUNT.** The Moonlight film's description
records three false claims and all three came from counting note STARTS in a bar
and concluding an instrument was absent. Every "is X playing here" statement above
is answered from `start <= t < start + length`, and `derive.py` prints the check:

    t= 93.017s  sounding: Figure 1  Tenor 1  Bass 1
    t=108.017s  sounding: Figure 0  Tenor 1  Bass 1
    t=123.017s  sounding: Figure 1  Tenor 1  Bass 1
    t=132.018s  sounding: Figure 0  Tenor 1  Bass 1

⚠ The two zeros are CORRECT and worth stating rather than explaining away: every
bar of the figure begins with a written eighth rest (`r8`), so at a bar line the
figure genuinely is not sounding. That is also why its largest onset-to-onset gap
is 0.750 s — the number that decides the rest-fade question below.

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

`ffmpeg -hide_banner -i out/bach-prelude.mp4 -af ebur128=peak=true -f null -`:
integrated **−14.0 LUFS**, true peak **−1.2 dBFS**, LRA **2.1 LU**.
Read off the mux, not off the intermediate `music.wav`.
