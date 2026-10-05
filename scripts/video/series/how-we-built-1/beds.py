#!/usr/bin/env python3
"""One audio bed per burst, EXACTLY as long as the burst is.

⚠ THIS LENGTH IS LOAD-BEARING. assemble.py sizes a PLAY segment from its
`loop` wav and then fits the burst to it — so a bed one second short cuts a
second off the animation, mid-sentence, and nothing errors. Every bed here is
cut to the burst's own measured `seconds` from bursts.json.

The demo track is the project's own render (`full.wav`); the diagram scenes get
`soft.wav`, the same eight bars with the drums, bass and lead excluded, so a
groove is not competing with a diagram.
"""
import json, os, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
SR = 48000
B = json.load(open(f"{HERE}/bursts.json"))

SRC = {
    "play-arrange": "full.wav", "play-roll": "full.wav",
    "drive-build": "full.wav", "drive-mix": "full.wav",
    "modules": "soft.wav", "journey-a": "soft.wav", "journey-b": "soft.wav",
}

for name, src in SRC.items():
    if name not in B:
        sys.exit(f"bursts.json has no '{name}' — run bursts.py first")
    secs = float(B[name])
    x, sr = sf.read(f"{HERE}/audio/{src}", dtype="float32", always_2d=True)
    assert sr == SR, sr
    n = int(round(secs * SR))
    reps = int(np.ceil(n / len(x)))
    y = np.tile(x, (reps, 1))[:n].copy()
    f = int(0.12 * SR)                      # short fades, no click at the join
    y[:f] *= np.linspace(0, 1, f)[:, None]
    y[-f:] *= np.linspace(1, 0, f)[:, None]
    out = f"{HERE}/audio/bed-{name}.wav"
    sf.write(out, y, SR, subtype="FLOAT")
    got = len(y) / SR
    if abs(got - secs) > 0.002:
        sys.exit(f"{name}: bed is {got:.3f}s, burst is {secs:.3f}s")
    print(f"  bed {name:14s} {got:6.3f}s  from {src}")
