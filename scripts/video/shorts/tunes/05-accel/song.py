#!/usr/bin/env python3
"""ACCELERANDO — one riff, 60 BPM to 180 BPM, and the grid visibly compressing.

E minor. A REAL TEMPO MAP: one {startBeat, bpm} segment per beat, 60 climbing to
180 across 64 beats, then four beats held at 180 for the landing. Nothing is
time-stretched -- the notes are the same beats throughout and the CLOCK moves,
which is why the beat lines in the picture squeeze together as it goes.

⚠ THE PICTURE AND THE SOUND INTEGRATE THE SAME MAP. viz.py's Timing and
DAWCore's TempoMap are both piecewise-CONSTANT over {startBeat, bpm} segments
(read from Commands.swift's parseTempoMap and TempoMap.seconds(fromBeatZeroTo:)),
so a beat line and the note under it are computed from the same arithmetic. The
sync gate is what proves they agreed, and on an accelerando it is the only thing
that could.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from theory import MIN, deg, N, shift, write

RAMP, HOLD = 64, 6
LEN = RAMP + HOLD
LO, HI = 60.0, 180.0
SEGS = [{"startBeat": k, "bpm": round(LO + (HI - LO) * k / (RAMP - 1), 4)} for k in range(RAMP)]
SEGS.append({"startBeat": RAMP, "bpm": HI})

secs = 0.0
for a, b in zip(SEGS, SEGS[1:]):
    secs += (b["startBeat"] - a["startBeat"]) * 60.0 / a["bpm"]
secs += HOLD * 60.0 / HI

ROOT = 52                                  # E3
S = lambda d: deg(ROOT, MIN, d)
BARS = LEN // 4

# The riff: one bar, driving, low-mid so a phone speaker can hear it.
RIFF = [(0.0, 0, 0.45, 118), (0.75, 0, 0.25, 84), (1.0, 3, 0.45, 104),
        (1.5, 0, 0.25, 88), (2.0, 5, 0.45, 110), (2.5, 4, 0.25, 90),
        (3.0, 3, 0.45, 106), (3.5, 0, 0.45, 96)]
riff, bass, kit, stab, timp = [], [], [], [], []
for bar in range(BARS):
    b = bar * 4.0
    riff += [N(b + t, S(d) + 12, l, v) for t, d, l, v in RIFF]
    bass += [N(b + t, S(d) - 12, l, min(127, v + 6)) for t, d, l, v in RIFF]
    kit += [N(b, 36, 0.3, 120), N(b + 1.0, 38, 0.3, 104), N(b + 2.0, 36, 0.3, 114),
            N(b + 2.5, 36, 0.3, 92), N(b + 3.0, 38, 0.3, 106)]
    kit += [N(b + k * 0.5, 42, 0.2, 88 if k % 2 == 0 else 60) for k in range(8)]
    if bar >= 3:
        stab += [N(b, p, 0.7, 100) for p in (S(0) + 12, S(2) + 12, S(4) + 12)]
    if bar >= 6:
        timp += [N(b, 40, 0.6, 108), N(b + 2.0, 47, 0.5, 92)]

E = RAMP * 1.0
riff += [N(E, S(0) + 24, 6.0, 120)]
bass += [N(E, S(0) - 12, 6.0, 118)]
kit += [N(E, 49, 2.0, 120), N(E, 36, 0.4, 127)]
stab += [N(E, p, 6.0, 110) for p in (S(0) + 12, S(2) + 12, S(4) + 12, S(7) + 12)]
timp += [N(E, 40, 2.0, 118)]

song = {
    "id": "accel", "title": "ACCELERANDO", "subtitle": "sixty to one hundred eighty · E minor",
    "legendMode": "list",
    "tempoSegments": SEGS,
    "beatsPerBar": 4, "lengthBeats": LEN, "renderSeconds": round(secs + 2.6, 2),
    "buses": [{"name": "Air", "volume": 0.8,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.55, "damping": 0.5,
                                                    "mix": 1.0, "preDelayMs": 12, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 2.0}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 70, "truePeak": 1}}]},
    "tracks": [
        {"name": "Overdrive guitar", "program": 29, "bankMSB": 121, "bankLSB": 0,
         "color": "#FF7A45", "volume": 0.72, "pan": -0.22, "send": {"bus": "Air", "level": 0.12},
         "notes": riff},
        {"name": "Synth bass", "program": 38, "bankMSB": 121, "bankLSB": 0,
         "color": "#FFC24D", "volume": 0.86, "pan": 0.0, "send": {"bus": "Air", "level": 0.05},
         "notes": bass},
        {"name": "Kit", "program": 16, "bankMSB": 120, "bankLSB": 0,
         "color": "#8FA3BF", "volume": 0.80, "pan": 0.08, "send": {"bus": "Air", "level": 0.10},
         "notes": kit},
        {"name": "Brass stabs", "program": 61, "bankMSB": 121, "bankLSB": 0,
         "color": "#FF5C8A", "volume": 0.62, "pan": 0.26, "send": {"bus": "Air", "level": 0.22},
         "notes": stab},
        {"name": "Timpani", "program": 47, "bankMSB": 121, "bankLSB": 0,
         "color": "#B39BFF", "volume": 0.78, "pan": -0.12, "send": {"bus": "Air", "level": 0.20},
         "notes": timp},
    ],
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
print(f"  ramp {LO}->{HI} over {RAMP} beats = {secs:.2f}s of music")
