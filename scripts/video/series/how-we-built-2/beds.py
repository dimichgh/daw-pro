#!/usr/bin/env python3
"""One audio bed per burst, EXACTLY as long as the burst is.

⚠ THIS LENGTH IS LOAD-BEARING. assemble.py sizes a PLAY segment from its
`loop` wav and then fits the burst to it — so a bed one second short cuts a
second off the animation, mid-sentence, and nothing errors.

The app footage plays THE PROJECT'S OWN CLEAN RENDER, unaltered and
un-normalised: it is one half of the film's demonstration, so it must be the
same twelve seconds the broken file was made from. The two diagram scenes get
`soft.wav` — the same eight bars with drums, bass and lead excluded — so a
groove is not competing with an explanation.
"""
import json, os, sys
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
SR = 48000
B = json.load(open(f"{HERE}/bursts.json"))
SRC = {"play-arrange": ("mix-clean.wav", False),   # (source, may loop)
       "deadline": ("soft.wav", True),
       "counter": ("soft.wav", True)}

for name, (src, may_loop) in SRC.items():
    if name not in B:
        sys.exit(f"bursts.json has no '{name}' — run bursts.py first")
    secs = float(B[name])
    x, sr = sf.read(f"{HERE}/audio/{src}", dtype="float32", always_2d=True)
    assert sr == SR, sr
    n = int(round(secs * SR))
    if n > len(x) and not may_loop:
        sys.exit(f"{name}: needs {secs:.2f}s but {src} is only {len(x)/SR:.2f}s "
                 "and must NOT be looped (it is the demonstration itself)")
    reps = int(np.ceil(n / len(x)))
    y = np.tile(x, (reps, 1))[:n].copy()
    if may_loop:
        f = int(0.12 * SR)
        y[:f] *= np.linspace(0, 1, f)[:, None]
        y[-f:] *= np.linspace(1, 0, f)[:, None]
    out = f"{HERE}/audio/bed-{name}.wav"
    sf.write(out, y, SR, subtype="FLOAT")
    got = len(y) / SR
    if abs(got - secs) > 0.002:
        sys.exit(f"{name}: bed is {got:.3f}s, burst is {secs:.3f}s")
    print(f"  bed {name:14s} {got:6.3f}s  from {src}"
          + ("  (verbatim, no fades)" if not may_loop else ""))

# ⚠ THE BROKEN FILE IS NOT A BED. It is played once, clean and unnormalised,
# under the waveform pictures. Assert here that it is still exactly as long as
# the clean one, because a length change would mean the excerpt moved.
a = sf.info(f"{HERE}/audio/mix-clean.wav")
b = sf.info(f"{HERE}/audio/mix-broken.wav")
if abs(a.frames - b.frames) != 0:
    sys.exit(f"clean {a.frames} frames vs broken {b.frames} — they must match")
print(f"  demonstration  {a.frames/SR:6.3f}s  clean and broken, identical length")
