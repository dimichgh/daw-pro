#!/usr/bin/env python3
"""The level envelopes the intro diagram draws — MEASURED, not illustrated.

The opening beat of the lesson says "a compressor turns the loud parts down".
Drawing that with an invented squiggle would be the one dishonest picture in a
film whose whole premise is predict-then-measure, so it is drawn from the SAME
two renders demo 3 uses: the dry pad-and-drums loop, and the same loop through
the compressor. Peak envelope, 10 ms windows, in dBFS.
"""
import json, os
import numpy as np, soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
WIN, T_MAX = 0.020, 3.0

def env(path):
    x, sr = sf.read(os.path.join(HERE, "audio", path), always_2d=True)
    x = np.max(np.abs(x), axis=1)[: int(T_MAX * sr)]
    h = int(WIN * sr)
    n = len(x) // h
    p = np.max(x[: n * h].reshape(n, h), axis=1)
    db = 20 * np.log10(np.maximum(p, 1e-6))
    return [[round(i * WIN, 3), round(float(v), 2)] for i, v in enumerate(db)]

out = {"windowSec": WIN, "tMaxSec": T_MAX,
       "dry": env("d3p-dry.wav"), "compressed": env("d3p-fast.wav"),
       "_": "peak envelope in dBFS, 10 ms windows, off the same renders demo 3 plays"}
json.dump(out, open(f"{HERE}/introenv.json", "w"))
d = np.array([v for _, v in out["dry"]]); c = np.array([v for _, v in out["compressed"]])
print(f"dry  max {d.max():.2f}  min {d.min():.2f} dBFS")
print(f"comp max {c.max():.2f}  min {c.min():.2f} dBFS")
print(f"biggest window-by-window reduction {float((d-c).max()):.2f} dB")
