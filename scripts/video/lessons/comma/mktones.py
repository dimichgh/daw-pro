#!/usr/bin/env python3
"""Source samples for the sampler zones. Exact 440.000 Hz at 48 kHz.

⚠ These are the ONLY hand-generated audio in the film, and they are generated
rather than played because the whole lesson is about EXACT frequency ratios: a
recorded note has vibrato, drift and inharmonicity, all of which would show up
in the beat measurement as noise. The RETUNING — which is the thing the film is
about — is done by the app's sampler, not here.

Length 24 s so that even a +702-cent (x1.5) varispeed read still covers a 12 s
note without running off the end of the file.
"""
import numpy as np, soundfile as sf, os
SR, F0, DUR = 48000, 440.0, 24.0
HERE = os.path.dirname(os.path.abspath(__file__))
t = np.arange(int(SR * DUR)) / SR

def env(x, ms=8.0):
    n = int(SR * ms / 1000)
    w = np.ones(len(x)); r = np.linspace(0, 1, n)
    w[:n] = r; w[-n:] = r[::-1]
    return x * w

sine = env(np.sin(2 * np.pi * F0 * t))
# band-limited saw: harmonics up to 8 kHz, so the 4th/5th partials that create
# the third's beat are present and the file is alias-free under varispeed.
saw = np.zeros_like(t)
for k in range(1, int(8000 // F0) + 1):
    saw += ((-1) ** (k + 1)) * np.sin(2 * np.pi * F0 * k * t) / k
saw = env(saw / np.max(np.abs(saw)))
os.makedirs(f"{HERE}/media", exist_ok=True)
for nm, x in (("sine440", sine), ("saw440", saw)):
    p = f"{HERE}/media/{nm}.wav"
    sf.write(p, (x * 0.5).astype(np.float32), SR)
    print(nm, p, len(x) / SR, "s  peak", float(np.max(np.abs(x * 0.5))))
