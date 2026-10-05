#!/usr/bin/env python3
"""THE CASCADE — a run down the sound bank, roughly a note per instrument.

D major pentatonic, 132 BPM, 24 bars. A continuous sixteenth-note arpeggio
sweeps up and down five octaves while the TIMBRE changes note by note, cycling
through twenty-four MuseScore General programs. In the picture that is a
diagonal ribbon crossing the whole frame in twenty-four colours, and the
instrument's name changes with it.

⚠ TWENTY-FOUR TRACKS, ONE PROGRAM EACH, is the only way to do this: an
instrument is a property of the TRACK, so "a different instrument on every note"
means a different track on every note. The notes are dealt round-robin.

⚠ COLOURS ARE A HUE RAMP, not a palette. With twenty-four parts a hand-picked
palette runs out of distinguishable colours; a ramp makes the ribbon read as one
moving object whose colour tells you where in the cycle you are.
"""
import colorsys, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from theory import PENT, deg, N, write

BPM, BARS = 132, 24
LEN = BARS * 4
ROOT = 38                                   # D2
D = lambda d: deg(ROOT, PENT, d)

# 24 programs, ordered so neighbours in the cycle are DIFFERENT families --
# a plucked, a struck, a blown, a bowed, round and round.
PROG = [("Grand piano", 0), ("Glockenspiel", 9), ("Nylon guitar", 24), ("Flute", 73),
        ("Marimba", 12), ("Pizzicato strings", 45), ("Clarinet", 71), ("Vibraphone", 11),
        ("Harp", 46), ("Oboe", 68), ("Celesta", 8), ("Steel guitar", 25),
        ("Trumpet", 56), ("Kalimba", 108), ("Recorder", 74), ("Music box", 10),
        ("Koto", 107), ("Piccolo", 72), ("Xylophone", 13), ("Harpsichord", 6),
        ("Banjo", 105), ("Pan flute", 75), ("Tubular bells", 14), ("Steel drums", 114)]

# The path: up 26 pentatonic degrees, down 26, three times, with the turnaround
# landing on a downbeat so the sweep reads as a wave rather than as a sawtooth.
UP, STEP = 30, 0.25
path, d, dirn = [], 0, 1
t = 0.0
while t < LEN - 4:
    path.append((t, d))
    d += dirn
    if d >= UP:
        d, dirn = UP - 1, -1
    if d < 0:
        d, dirn = 1, 1
    t += STEP

parts = [[] for _ in PROG]
for i, (t, dg) in enumerate(path):
    v = 84 + (i % 4 == 0) * 26                 # a small accent on every beat
    parts[i % len(PROG)].append(N(t, D(dg), 0.7, v))

# The landing: a wide D chord across four of the twenty-four, ringing out.
E = (BARS - 1) * 4.0
for k, p in ((0, 38), (4, 62), (8, 69), (12, 74), (16, 81), (20, 86)):
    parts[k].append(N(E, p, 8.0, 104))

# A low bowed bed and a timpani on every bar line, so the ribbon has a floor.
bed = [N(bar * 4.0, p, 4.0, 56) for bar in range(BARS - 1) for p in (38, 45, 50)]
timp = [N(bar * 4.0, 38 if bar % 2 == 0 else 45, 0.8, 96) for bar in range(BARS - 1)]
bed.append(N(E, 38, 8.0, 70))
timp.append(N(E, 38, 2.0, 110))

tracks = []
for i, (name, prog) in enumerate(PROG):
    h = i / len(PROG)
    r, g, b = colorsys.hsv_to_rgb(h, 0.62, 1.0)
    tracks.append({"name": name, "label": name, "program": prog, "bankMSB": 121, "bankLSB": 0,
                   "color": "#%02X%02X%02X" % (int(r * 255), int(g * 255), int(b * 255)),
                   "volume": 0.62, "pan": round(-0.42 + 0.84 * (i % 7) / 6, 2),
                   "send": {"bus": "Air", "level": 0.30}, "notes": parts[i]})
tracks += [
    {"name": "Bowed bed", "label": "Bowed bed", "program": 49, "bankMSB": 121, "bankLSB": 0,
     "color": "#3A4A63", "volume": 0.50, "pan": 0.0, "vizAlpha": 0.40, "legendIgnore": True,
     "send": {"bus": "Air", "level": 0.40}, "notes": bed},
    {"name": "Timpani", "label": "Timpani", "program": 47, "bankMSB": 121, "bankLSB": 0,
     "color": "#6E7C93", "volume": 0.72, "pan": 0.0, "vizAlpha": 0.65, "legendIgnore": True,
     "send": {"bus": "Air", "level": 0.24}, "notes": timp},
]

song = {
    "id": "cascade", "title": "THE CASCADE",
    "subtitle": "one note, one instrument · twenty-four of them · D pentatonic · 132",
    "legendMode": "current", "legendHold": 0.34,
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN, "renderSeconds": round(LEN * 60 / BPM + 3.0, 2),
    "buses": [{"name": "Air", "volume": 0.95,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.80, "damping": 0.32,
                                                    "mix": 1.0, "preDelayMs": 26, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 2.6}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 90, "truePeak": 1}}]},
    "tracks": tracks,
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
