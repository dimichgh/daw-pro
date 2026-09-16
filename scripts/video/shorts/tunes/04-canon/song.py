#!/usr/bin/env python3
"""THE CANON — three voices, one line, entering in sequence.

E major pentatonic at 116 BPM. The whole point is that the imitation is VISIBLE:
the same shape falls three times down the frame in three colours, offset by 8
and 20 beats, and a viewer who could not name a canon can see one.

⭐ WHY PENTATONIC. A strict canon has to consonate against a displaced copy of
itself at EVERY offset it is played at. In a diatonic scale that is a
composition problem; in a pentatonic one it is nearly free, because the scale
contains no semitone. So the entries could be chosen for the PICTURE (staggered,
non-multiples of the phrase length, so the shapes interlock rather than line up)
instead of for the harmony.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from theory import PENT, deg, N, shift, repeat, clip_to, write

BPM = 116
ROOT = 64                       # E4
PHRASE = 16.0                   # beats
BARS = 21
LEN = BARS * 4                  # 84 beats
D = lambda d: deg(ROOT, PENT, d)

# The subject: 31 eighths, one arch, mostly stepwise in the pentatonic.
SUBJ_DEG = [
    (0.0, 4), (0.5, 6), (1.0, 8), (1.5, 6), (2.0, 4), (2.5, 3), (3.0, 4), (3.5, 6),
    (4.0, 3), (4.5, 5), (5.0, 7), (5.5, 5), (6.0, 3), (6.5, 2), (7.0, 3), (7.5, 5),
    (8.0, 6), (8.5, 8), (9.0, 9), (9.5, 8), (10.0, 6), (10.5, 5), (11.0, 4), (11.5, 5),
    (12.0, 2), (12.5, 4), (13.0, 6), (13.5, 4), (14.0, 2), (14.5, 1), (15.0, 2),
]
VEL = [102, 78, 92, 76, 96, 74, 88, 74]        # a lilt on the eighths


def subject(dshift, vel_bias=0):
    out = []
    for i, (t, d) in enumerate(SUBJ_DEG):
        ln = 1.0 if t == 15.0 else 0.46
        out.append(N(t, D(d + dshift), ln, VEL[i % 8] + vel_bias))
    return out


# Voice 1 marimba from bar 1; voice 2 vibraphone an octave down from beat 8;
# voice 3 celesta a pentatonic third up from beat 20. Offsets 8 and 4 modulo the
# phrase, so no two voices ever line up.
v1 = clip_to(repeat(subject(0), PHRASE, 6, 0.0), 76.0)
v2 = clip_to(repeat(subject(-5, -6), PHRASE, 6, 8.0), 76.0)
v3 = clip_to(repeat(subject(2, -14), PHRASE, 6, 20.0), 72.0)

# Bass: pizzicato roots, two bars each, E - C# - A - B.
ROOTS = [40, 37, 45, 47]
bass = []
for bar in range(6, BARS - 1):
    r = ROOTS[((bar - 6) // 2) % 4]
    b = bar * 4.0
    for t, p, v in ((0.0, r, 104), (1.5, r + 12, 72), (2.0, r + 7, 84), (3.5, r + 12, 66)):
        bass.append(N(b + t, p + (0 if p < 60 else 0), 1.2 if t in (0.0, 2.0) else 0.4, v))

# Pad: a slow bowed-glass bed from bar 9, one chord per two bars.
CH = [[52, 59, 64, 68], [49, 56, 61, 68], [45, 52, 57, 64], [47, 54, 59, 66]]
pad = []
for k, bar in enumerate(range(8, BARS - 1, 2)):
    for p in CH[k % 4]:
        pad.append(N(bar * 4.0, p, 8.0, 58))

# The landing: everything stops and one wide E chord rings for the last two bars.
END = (BARS - 1) * 4.0          # beat 80
final_v = [N(END, p, 8.0, 96) for p in (64, 71, 76, 83)]
final_b = [N(END, 40, 8.0, 100), N(END, 52, 8.0, 74)]
final_p = [N(END, p, 8.0, 66) for p in (52, 59, 64, 68)]

song = {
    "id": "canon", "title": "THE CANON", "subtitle": "one line · three voices · E pentatonic · 116",
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN, "renderSeconds": round(LEN * 60 / BPM + 3.2, 2),
    "buses": [{"name": "Air", "volume": 0.9,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.78, "damping": 0.34,
                                                    "mix": 1.0, "preDelayMs": 24, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 5.6}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 90, "truePeak": 1}}]},
    "tracks": [
        {"name": "Marimba · voice 1", "program": 12, "color": "#5AD1FF",
         "volume": 0.92, "pan": -0.34, "send": {"bus": "Air", "level": 0.22},
         "notes": v1 + final_v},
        {"name": "Vibraphone · voice 2", "program": 11, "color": "#A78BFA",
         "volume": 0.86, "pan": 0.32, "send": {"bus": "Air", "level": 0.30},
         "notes": v2},
        {"name": "Celesta · voice 3", "program": 8, "color": "#7DF9D6",
         "volume": 0.80, "pan": 0.05, "send": {"bus": "Air", "level": 0.34},
         "notes": v3},
        {"name": "Pizzicato bass", "program": 45, "color": "#FFB84D",
         "volume": 0.95, "pan": -0.06, "send": {"bus": "Air", "level": 0.10},
         "notes": bass + final_b},
        {"name": "Bowed glass pad", "program": 92, "color": "#4C6E9B",
         "volume": 0.52, "pan": 0.0, "send": {"bus": "Air", "level": 0.40},
         "notes": pad + final_p},
    ],
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
