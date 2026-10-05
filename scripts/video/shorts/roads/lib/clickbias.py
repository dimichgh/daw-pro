#!/usr/bin/env python3
"""POSITIVE CONTROL for the onset detector's own latency.

40 clicks at exactly known times through sync.py's own onsets(). Whatever this
prints is the bias every median-offset figure in this series carries, and the
reason the picture lag is NOT simply the measured offset.

    python3 clickbias.py            # expect ~40/40 and a NEGATIVE median bias
    python3 clickbias.py --shift 25 # NEGATIVE CONTROL: moves the answer by +25 ms
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, "/Users/dsemenov/Views/daw-pro/scripts/video/shorts/tunes/lib")
from sync import onsets, SR

ap = argparse.ArgumentParser()
ap.add_argument("--shift", type=float, default=0.0, help="ms to move the clicks by")
a = ap.parse_args()
rng = np.random.default_rng(11)
times = np.sort(rng.uniform(0.5, 28.0, 40))
x = np.zeros(int(30 * SR), np.float32)
for t in times:
    i = int(round((t + a.shift / 1000.0) * SR))
    env = np.exp(-np.arange(400) / 60.0)
    x[i:i + 400] += (np.sin(2 * np.pi * 1000 * np.arange(400) / SR) * env).astype(np.float32)
det = onsets(x)
j = np.searchsorted(times, det); j = np.clip(j, 1, len(times) - 1)
near = np.where(np.abs(det - times[j - 1]) < np.abs(det - times[j]), times[j - 1], times[j])
d = det - near
d = d[np.abs(d) < 0.06]
print(f"clicks {len(times)}  detected {len(det)}  matched {len(d)}")
print(f"median bias {np.median(d)*1000:+.1f} ms   spread {(d.max()-d.min())*1000:.1f} ms")
