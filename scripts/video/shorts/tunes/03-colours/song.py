#!/usr/bin/env python3
"""ONE LINE, TWELVE COLOURS — the same eight beats, twelve times, twelve
instruments. The notes never change; only the timbre does.

D major, 126 BPM, 24 bars. The claim is falsifiable and is checked: `identity.py`
reads the twelve clips BACK out of the DAW and asserts that, once each clip's own
start beat is subtracted, all twelve carry byte-identical note tuples. That check
is run once with a note deliberately mutated, and it fails.

The two backing parts (bass, kit) are NOT part of the claim and are excluded by
name -- they carry the groove that makes twelve repetitions listenable.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from theory import MAJ, deg, N, shift, write

BPM, PHRASE, REPS = 126, 8.0, 12
LEN = int(PHRASE * REPS) + 8
ROOT = 62                                   # D4
D = lambda d: deg(ROOT, MAJ, d)

# THE LINE. Eight beats, sixteen notes, one hook.
LINE = [(0.0, 4, 0.5, 104), (0.5, 2, 0.5, 82), (1.0, 0, 1.0, 96), (2.0, 2, 0.5, 88),
        (2.5, 4, 0.5, 84), (3.0, 5, 1.0, 100), (4.0, 4, 0.5, 92), (4.5, 2, 0.5, 80),
        (5.0, 1, 1.0, 98), (6.0, -1, 0.5, 86), (6.5, 1, 0.5, 82), (7.0, 0, 1.0, 104)]
PHRASE_NOTES = [N(t, D(d), l, v) for t, d, l, v in LINE]

VOICES = [("Grand piano", 0, 121, "#FF6B6B"), ("Nylon guitar", 24, 121, "#FF9A5C"),
          ("Marimba", 12, 121, "#FFC24D"), ("Flute", 73, 121, "#EDE05A"),
          ("Trumpet", 56, 121, "#B8E85A"), ("Violin", 40, 121, "#6FE08A"),
          ("Church organ", 19, 121, "#4FDDC0"), ("Clarinet", 71, 121, "#4FD0F0"),
          ("Vibraphone", 11, 121, "#5AA8FF"), ("Steel drums", 114, 121, "#8C8CFF"),
          ("Choir", 52, 121, "#C07BFF"), ("Square lead", 80, 121, "#FF6FD0")]

tracks = []
for i, (name, prog, msb, col) in enumerate(VOICES):
    tracks.append({"name": name, "label": name, "program": prog, "bankMSB": msb, "bankLSB": 0,
                   "color": col, "volume": 0.80, "pan": round(-0.30 + 0.06 * i, 2),
                   "send": {"bus": "Air", "level": 0.24},
                   "identity": True,
                   "notes": shift(PHRASE_NOTES, i * PHRASE)})

# Backing, unbroken underneath: a walking bass and a light kit.
ROOTS = [50, 45, 48, 52]                    # D  A  C  E  -- one per two phrases
bass, kit = [], []
for bar in range(REPS * 2 + 2):
    r = ROOTS[(bar // 2) % 4]
    b = bar * 4.0
    bass += [N(b, r - 12, 1.4, 104), N(b + 1.5, r - 5, 0.4, 76),
             N(b + 2.0, r - 12, 1.4, 96), N(b + 3.5, r, 0.4, 78)]
    kit += [N(b, 36, 0.3, 108), N(b + 2.0, 38, 0.3, 92)]
    kit += [N(b + k * 0.5 + 0.25, 42, 0.2, 62) for k in range(8)]

tracks += [
    {"name": "Bass", "label": "Bass", "program": 33, "bankMSB": 121, "bankLSB": 0,
     "color": "#5A6B86", "volume": 0.88, "pan": 0.0, "vizAlpha": 0.55, "legendIgnore": True,
     "send": {"bus": "Air", "level": 0.06}, "notes": bass},
    {"name": "Kit", "label": "Kit", "program": 0, "bankMSB": 120, "bankLSB": 0,
     "color": "#465266", "volume": 0.60, "pan": 0.0, "vizAlpha": 0.55, "legendIgnore": True,
     "send": {"bus": "Air", "level": 0.08}, "notes": kit},
]

song = {
    "id": "colours", "title": "ONE LINE", "subtitle": "twelve colours · the notes never change",
    "legendMode": "current", "legendHold": 0.5,
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN, "renderSeconds": round(LEN * 60 / BPM + 2.4, 2),
    "identityPhrase": PHRASE,
    "buses": [{"name": "Air", "volume": 0.9,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.60, "damping": 0.42,
                                                    "mix": 1.0, "preDelayMs": 16, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 2.4}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 80, "truePeak": 1}}]},
    "tracks": tracks,
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
