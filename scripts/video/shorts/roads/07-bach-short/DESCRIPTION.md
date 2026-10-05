# YouTube description block — paste as-is (VERTICAL SHORT)

⛔ UPLOAD AS A **PRIVATE DRAFT** ONLY, AND NOT BY US. Publishing, scheduling and
visibility are the user's actions in YouTube Studio. Nothing in this round was
uploaded anywhere.

---

## Title

    Bach's Prelude in C — the first eleven bars, as a road of light #Shorts

## Description (paste below the line)

---
The opening of J. S. Bach's Prelude in C, BWV 846 — bars 1 to 11, ending on the
first big arrival in the piece.

The score IS the road. Time runs away from you down the page: each staff is a
lane, each note sits where it really sits on the stave, and the three lights are
the three voices Bach actually wrote — the broken-chord figure in the right hand,
and the two held voices underneath it that the left hand plays as one gesture.

The figure never changes shape. Watch the two quiet lights on the right instead:
across bars nine, ten and eleven the harmony drops a fifth each time — A, then D,
then G. At 0:40 it lands on a plain G major chord, the first structural arrival
in the piece, and the cut runs to the end of that bar and stops, at 0:44. That is
why this excerpt ends where it does rather than at a round number of seconds.

(The bass writes the last of those three steps as a rising fourth rather than a
falling fifth — the same root motion.)

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

The complete thirty-five-bar film is a separate video.
---

## ⚠ No CHAPTERS block, deliberately

A 44-second vertical Short has no chapter surface, and three marks inside forty
seconds would be noise where it did. `derive.py` prints a chapter block for this
directory anyway (so the numbers exist and can be checked); it is not used here.

## ⚠ Every number above is DERIVED. `derive.py` prints this table.

`python3 ../06-bach-prelude/derive.py .` reads THIS directory's `song.json` and
`out/payload.json` and re-derives all of it. There is **one** deriver, shared with
06 and 08 — round 31 shipped a wrong timestamp (bar 32 for bar 33) that was a
number typed into a copy of this file, and a second copy is a second place for
that to happen.

| moment | derived from | seconds | m:ss |
|---|---|---|---|
| the piece begins | bar 1 line; BOTH left-hand voices sound at beat 0 and the figure at beat 0.5 | 0.018 | 0:00 |
| bar 11 — the arrival lands | bar line, (11-1)*4 beats at the session tempo + the lag | 40.017 | 0:40 |
| the figure's last note | last figure onset, beat 43.75, 1 notes, 0.25 beats long | 43.767 | 0:43 |
| the last sound ends | max(start+length) over all three roads, beat 44 | 44.017 | 0:44 |
| the end card begins | song.json look.endCard.at | 45.400 | 0:45 |
| the film ends | last of 1596 rendered frames: (1596-1)/30 | 53.167 | 0:53 |


### Why bars 1–11 — computed, not asserted

`derive.py`'s SPAN block, on this directory:

      root-motion-by-fifth chain in the bass terminating at bar 11 (each root a fifth below the last, register free — a rising fourth is the same motion): bars 9-11 = A3 -> D3 -> G3  (3 bars)
      bar 11 chord over its own bass: intervals [0, 4, 7] = major on G3
      bar 12 in the FULL score (06/song.json): bass G3 — the chain does NOT continue, bar 11 is its terminus
      the arrival LANDS at bar 11's line, 40.017s = 0:40; the excerpt runs to the END of that bar and stops at 44.017s = 0:44, not partway into the next move

⚠ **The chain test needed correcting before it was believed.** The first version
required the bass to FALL in pitch and measured a chain of ONE, because bars 9–11
read A3(57) → D3(50) → **G3(55)**: the last step RISES a fourth. A fourth up and
a fifth down are the same root motion. The pitch-class test is the whole test.

⭐ **And two rows that are NOT here are the point of the exercise.** This span has
no G2 pedal (its longest single-pitch bass run is 6 onsets, one bar's worth) and
no pattern break (the figure's half-bars are identical in all eleven bars).
`derive.py` says so in words rather than printing a row that would read like a
measurement and be an artefact of the window.

## ⚠ AN ONSET COUNT IS NOT A SOUNDING COUNT

Every "is X playing here" statement is answered from `start <= t < start + length`.
`derive.py` prints the check:

    t=  1.018s  sounding: Figure 1  Tenor 1  Bass 1
    t= 16.017s  sounding: Figure 1  Tenor 1  Bass 1
    t= 41.017s  sounding: Figure 1  Tenor 1  Bass 1
    t= 43.017s  sounding: Figure 1  Tenor 1  Bass 1

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

`ffmpeg -hide_banner -i out/bach-short.mp4 -af ebur128=peak=true -f null -`:
integrated **−14.0 LUFS**, true peak **−2.8 dBFS**, LRA **1.8 LU**.
Read off the mux, not off the intermediate `music.wav`.

## ⚠ THE ENDING, STATED RATHER THAN BURIED

An excerpt of this piece cannot end on a rest, because the piece has none: the
figure runs unbroken sixteenths from bar 1 to bar 33. So this cut stops the
sixteenths at the bar line. Measured on the mux, per 100 ms:

    43.90 s  −21.3 dBFS      the last full sixteenth
    44.00 s  −28.4
    44.10 s  −41.0           the notes have stopped; this is the release tail
    46.40 s  silence

The **shape** of that stop is the same as the approved 35-bar film's own ending
(−37.1 → −43.5 → −54.6 across the same three windows). What differs is the level
it stops FROM: the complete film's last bar is a fermata already decaying, and
this one is cut at full flow. Nothing has been faded to hide it — see NOTES
ROUND 32 §5 for the options that were measured and not taken.
