#!/usr/bin/env python3
"""One audio bed per burst that needs one, EXACTLY as long as the burst.

⚠ THIS LENGTH IS LOAD-BEARING. assemble.py sizes a PLAY segment from its `loop`
wav and fits the burst to it, so a bed one second short cuts a second off the
animation mid-sentence and nothing errors.

play-arrange and slowcap play the project's own render verbatim. The two manim
scenes get soft-bed.wav — the same passage with Drums and Lead excluded at
render time — so a groove is not competing with an explanation. The two flam
sweeps use the demonstration wavs themselves and get no bed here.
"""
import json, os, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
SR = 48000
B = json.load(open(f"{HERE}/bursts.json"))
SRC = {"play-arrange": ("mix-clean.wav", False),
       "slowcap":      ("mix-clean.wav", False),
       "vacuous":      ("soft-bed.wav", True),
       "falsify":      ("soft-bed.wav", True)}

for name, (src, may_loop) in SRC.items():
    secs = float(B[name])
    x, sr = sf.read(f"{HERE}/audio/{src}", dtype="float32", always_2d=True)
    assert sr == SR, sr
    n = int(round(secs * SR))
    if n > len(x) and not may_loop:
        sys.exit(f"{name}: needs {secs:.2f}s but {src} is {len(x)/SR:.2f}s and must not loop")
    y = np.tile(x, (int(np.ceil(n / len(x))), 1))[:n].copy()
    if may_loop:
        y *= 10 ** (-6.0 / 20)
        f = int(0.12 * SR)
        y[:f] *= np.linspace(0, 1, f)[:, None]
        y[-f:] *= np.linspace(1, 0, f)[:, None]
    out = f"{HERE}/audio/bed-{name}.wav"
    sf.write(out, y, SR, subtype="FLOAT")
    got = len(y) / SR
    if abs(got - secs) > 0.002:
        sys.exit(f"{name}: bed is {got:.3f}s, burst is {secs:.3f}s")
    print(f"  bed {name:14s} {got:6.3f}s from {src}"
          + ("  (verbatim, no fades)" if not may_loop else ""))
