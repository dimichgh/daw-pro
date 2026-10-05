# YouTube description block — paste as-is

⛔ UPLOAD AS A **PRIVATE DRAFT** ONLY. Publishing, scheduling and visibility are
the user's actions in YouTube Studio, never ours.

---

## Title

    Beethoven — Moonlight Sonata, 1st movement (bars 1–42) · a road of light

## Description (paste below the line)

---
Beethoven's Sonata quasi una fantasia in C♯ minor, Op. 27 No. 2 — the Adagio
sostenuto, from the first bar through the return of the tonic at bar 42.

The score IS the road. Time runs away from you down the page: each staff is a
lane, each note is where it actually sits on the stave, and the three lights are
the three strands of the music — the melody, the triplet accompaniment that never
stops for the whole movement, and the bass.

Watch for the moment the melody enters at 0:20 over an accompaniment that has
already been running for twenty seconds; the long dominant pedal from 2:12 where
the melody drops out entirely and the triplets and the bass hold it up alone —
from 2:25 the bass stops moving and simply holds one low octave for twelve beats
under them; and the melody's return at 2:36 into the descent.

Built and rendered end to end in DAW Pro — an AI-native DAW for macOS. The
performance, the mix, the loudness pass and the visualiser are all one pipeline;
nothing here was recorded from a screen.

—

SCORE / LICENCE
Visualisation inspired by Polyfjord — thank you for the idea.

Notes derived from the Mutopia Project edition Mutopia-2007/02/11-276, engraved
by Stewart Holmes from the Berners edition of 1908, edited by A. Winterberger.
Used under Creative Commons Attribution-ShareAlike 2.5:
https://creativecommons.org/licenses/by-sa/2.5/
Source: https://www.mutopiaproject.org/

The composition itself is in the public domain.

AUDIO
Rendered offline at 48 kHz, normalised to −14 LUFS integrated with a −1 dBTP
ceiling (the usual streaming convention).

CHAPTERS
0:00 Bars 1–4 — the accompaniment alone
0:20 Bar 5 — the melody enters
1:34 Bars 23–31 — the middle
2:12 Bar 32 — the melody drops out, the pedal holds
2:36 Bars 37–40 — the melody returns, the descent
2:55 Bar 42 — the tonic returns
---

## ⚠ Numbers in this text that must agree with the film

Every timing above is derived, not typed from memory. Re-derive them if the span
or the tempo ever changes:

| chapter | derived from | seconds | m:ss |
|---|---|---|---|
| melody enters | first melody onset in the payload | 20.375 | 0:20 |
| the middle | bar 23 line, `P.bars[22].t` | 94.303 | 1:34 |
| melody drops out | bar 32 line | 132.875 | 2:12 |
| bass stops MOVING (holds) | bar-35 bass onset, 12 beats long | 145.714 | 2:25 |
| melody returns | first melody onset after the gap, bar 37 | 156.429 | 2:36 |
| the descent | bar 37 line | 154.303 | 2:34 — the chapter is placed at the melody’s return, 2:36 |
| tonic returns | bar 42 line | 175.732 | 2:55 |

The loudness figures must be re-read off the FINISHED MUX, not off the intermediate
`music.wav` — see NOTES.md's round-17 measurements.


---

## The Short (portrait cut) — its own text

The Short is bars 1–9, not the first N seconds of the long film: it ends on the
melody's first full phrase rather than mid-bar. Its own end card says
"bars 1–9", so the long film's description does NOT fit it.

### Title

    Beethoven's Moonlight Sonata, as a road of light #Shorts

### Description (paste below the line)

---
The opening of the Adagio sostenuto, Op. 27 No. 2 — four bars of accompaniment,
triplets over a slow bass, and then the melody entering above them.

The score IS the road: each staff is a lane, each note sits where it really sits
on the stave, and the three lights are the melody, the triplets and the bass.
Rendered end to end in DAW Pro.

Visualisation inspired by Polyfjord — thank you for the idea.

Notes from the Mutopia Project edition Mutopia-2007/02/11-276, engraved by
Stewart Holmes from the Berners edition of 1908, ed. A. Winterberger, used under
CC BY-SA 2.5 — https://creativecommons.org/licenses/by-sa/2.5/
The composition is in the public domain.
---

No chapters: YouTube does not show them on a Short.

## ⚠ Claims in the long-film text that were WRONG and are now measured

"the triplets carry alone" from 2:12 was false, and MY FIRST CORRECTION OF IT
WAS ALSO FALSE. Counting onsets alone, the bass looks silent in bars 36-37, and I
wrote "for two bars the triplets really are on their own". Reading the NOTE
DURATIONS out of `03-moonlight-long/song.json` kills that too: the bar-35 bass
octave (beat 136, 145.71 s) is **12 beats long** and sounds until 158.57 s. The
bass is never silent under the pedal — it stops MOVING, which is a different
statement, and an onset count cannot tell the two apart. Nor were the triplets
alone for two bars: the melody returns at beat 146 = **156.43 s**, inside bar 37,
not at the bar-37 line. Melody: last note ends 132.86 s, no onsets bars 32-36.
The chapter for the middle was typed as 1:35 while this file's own derivation
table said 94.303 s = 1:34; the table was right. And the Short's text said "four
bars of triplets alone" while its own opened frame at t=5 shows two lit bass
lights — the bass plays from beat 0 there too.

⭐ **THE TRANSFERABLE ONE: an onset count is not a sounding count.** Three of the
four false claims in this file came from counting note STARTS in a bar and
concluding an instrument was absent.

## A/V sync, measured on the FINISHED MUX (not predicted)

`../tunes/lib/sync.py <mp4> song.json --roads --lead 0.0175`:

| film | matched @35 ms | median offset | drift end-to-end | wrong-phase control |
|---|---|---|---|---|
| long, 189.2 s | 94.1 % | −12.6 ms | **2.4 ms** | 2.0 % / 2.7 % (random 24.9 %) |
| Short, 47.8 s | 96.4 % | −13.0 ms | **4.4 ms** | 0.0 % / 3.6 % (random 22.7 %) |

Drift is the number that had never been measured at length, and it is ~1/14 of a
frame across three minutes. The −12.6 ms median is the SAME residual measured on
the 8-bar cut (−12.9 ms), which is the standing `vizLagMs 17.5` question: the
constant is stable, it is just not zero-centred. Both controls fire.
