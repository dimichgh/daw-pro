#!/usr/bin/env python3
"""THE LANTERN — E minor, 88 BPM, a slow lyrical clarinet line on the road.

The first of three. Slowest of the set and the one with the biggest leaps: the
arc between two notes is scaled by the interval, so a ninth is what makes the
light really fly. Steps carry the phrase, the leaps punctuate it.

⚠ ONE LINE ON THE ROAD. The clarinet is the only track with "road": true and it
is strictly monophonic — road.py refuses otherwise. The harp, strings and
contrabass are accompaniment; the harp is marked `roadSide` so it reads as faint
lights on the shoulders rather than as notation.

⚠ EVERY MELODY PITCH IS DIATONIC IN E MINOR. The staff is drawn by LETTER name,
so a pitch outside the key has no staff position and road.py raises rather than
placing it silently on the wrong line.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "tunes", "lib"))
from theory import MIN, deg, N, write

BPM, BARS = 88, 16
LEN = BARS * 4
ROOT = 52                                   # E3
E = lambda d: deg(ROOT, MIN, d)

# (beat, degree, length) — degree 0 = E3, 7 = E4, 14 = E5.
MEL = [
    # A — the phrase, stepwise with a third to open it
    (0.0, 7, 1.0), (1.0, 9, 0.5), (1.5, 11, 0.5), (2.0, 12, 1.5), (3.5, 11, 0.5),
    (4.0, 9, 1.0), (5.0, 7, 0.5), (5.5, 6, 0.5), (6.0, 7, 2.0),
    (8.0, 4, 1.0), (9.0, 7, 0.5), (9.5, 9, 0.5), (10.0, 11, 1.0),
    (11.0, 12, 0.5), (11.5, 13, 0.5), (12.0, 11, 2.0), (14.0, 9, 1.0), (15.0, 7, 1.0),
    # A' — the same opening, lifted, and it does not come home
    (16.0, 7, 1.0), (17.0, 9, 0.5), (17.5, 11, 0.5), (18.0, 12, 1.5), (19.5, 13, 0.5),
    (20.0, 14, 1.0), (21.0, 12, 1.0), (22.0, 11, 2.0),
    (24.0, 15, 1.0), (25.0, 14, 0.5), (25.5, 13, 0.5), (26.0, 12, 1.0),
    (27.0, 10, 1.0), (28.0, 11, 2.0), (30.0, 9, 2.0),
    # B — the leaps. 14->6 is a ninth down, 6->13 an octave and a fifth up.
    (32.0, 14, 1.5), (33.5, 13, 0.5), (34.0, 11, 1.0), (35.0, 14, 1.0),
    (36.0, 15, 1.0), (37.0, 13, 1.0), (38.0, 12, 2.0),
    (40.0, 5, 1.0), (41.0, 9, 0.5), (41.5, 11, 0.5), (42.0, 13, 1.0),
    (43.0, 14, 1.0), (44.0, 15, 1.5), (45.5, 13, 0.5), (46.0, 12, 2.0),
    # A'' — home
    (48.0, 7, 1.0), (49.0, 9, 0.5), (49.5, 11, 0.5), (50.0, 12, 1.5), (51.5, 11, 0.5),
    (52.0, 9, 1.0), (53.0, 6, 1.0), (54.0, 7, 2.0),
    (56.0, 11, 1.0), (57.0, 9, 0.5), (57.5, 7, 0.5), (58.0, 6, 1.0), (59.0, 4, 1.0),
    (60.0, 7, 4.0),
]
mel = [N(b, E(d), l, 96 + (12 if b % 4 == 0 else 0)) for b, d, l in MEL]

# i - VI - III - VII, four bars a turn, all diatonic in E natural minor.
CH = [[0, 2, 4], [5, 7, 9], [2, 4, 6], [6, 8, 10]]      # degrees over E3
harp, pad, bass = [], [], []
for bar in range(BARS):
    ch = CH[bar % 4]
    b0 = bar * 4.0
    # harp: a rising arpeggio in eighths, two per bar
    for k, off in enumerate([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5]):
        d = ch[k % 3] + 7 * (k // 3)
        harp.append(N(b0 + off, E(d), 0.5, 62 + (10 if k % 4 == 0 else 0)))
    for d in ch:
        pad.append(N(b0, E(d) + 12, 4.0, 52))
    bass.append(N(b0, E(ch[0]) - 12, 3.6, 74))
    bass.append(N(b0 + 2.5, E(ch[0]) - 5, 1.2, 62))

song = {
    "id": "lantern", "title": "THE LANTERN",
    "subtitle": "one line, one light  ·  E minor  ·  88",
    "keyRoot": 4, "keyScale": "minor", "bottomLinePitch": E(5),   # centre the line on the staff
    "vizLagMs": 0.0,
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN,
    "renderSeconds": round(LEN * 60 / BPM + 3.4, 2),
    "buses": [{"name": "Air", "volume": 0.95,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.82, "damping": 0.30,
                                                    "mix": 1.0, "preDelayMs": 30, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 2.8}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 90, "truePeak": 1}}]},
    "tracks": [
        {"name": "Clarinet", "label": "Clarinet", "program": 71, "road": True,
         "color": "#FFC46B", "volume": 0.90, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.26}, "notes": mel},
        {"name": "Harp", "label": "Harp", "program": 46, "roadSide": True, "roadSideU": 0.74,
         "color": "#7FD8FF", "volume": 0.52, "pan": -0.22,
         "send": {"bus": "Air", "level": 0.38}, "notes": harp},
        {"name": "Strings", "label": "Strings", "program": 49,
         "color": "#4C6A9A", "volume": 0.40, "pan": 0.18,
         "send": {"bus": "Air", "level": 0.44}, "notes": pad},
        {"name": "Contrabass", "label": "Contrabass", "program": 43,
         "color": "#3E4C63", "volume": 0.66, "pan": 0.0,
         "send": {"bus": "Air", "level": 0.16}, "notes": bass},
    ],
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
