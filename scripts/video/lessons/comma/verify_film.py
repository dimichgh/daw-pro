#!/usr/bin/env python3
"""Verify THE DELIVERABLE, not the work directory.

⭐ verify.py's A/B separation check compares LOUDNESS. This film's whole
demonstration is a BEAT RATE, which loudness cannot see: a pair whose halves are
level-matched to 0.1 LU passes that check whether or not the beating survived
assembly — and the first build of this film shipped an A/B that alternated ONE
FILE AGAINST ITSELF and passed it at +0.00 -> +0.00. So this pulls each half's
audio back out of the finished mp4 at the position `L4v2.mp4.timeline.json`
records and re-runs the same estimator measure.py used.

The control is the BEFORE half of each pair, which cannot beat.
"""
import json, os, subprocess, sys
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfiltfilt, hilbert

HERE = os.path.dirname(os.path.abspath(__file__))
FILM = f"{HERE}/out/L4v2.mp4"
TL = json.load(open(f"{FILM}.timeline.json"))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
SR = 48000
TMP = "/tmp/comma-verify"
os.makedirs(TMP, exist_ok=True)
PARTIAL = {"11-cost-third": M["material"]["partial"]["third"]}


def grab(t0, t1, out):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-ss", f"{t0:.3f}", "-i", FILM, "-t", f"{t1-t0:.3f}",
                    "-vn", "-ac", "1", "-ar", str(SR), out], check=True)
    x, sr = sf.read(out)
    return x


def bp(x, f0, q=0.25):
    lo, hi = f0 * 2 ** -q, f0 * 2 ** q
    return sosfiltfilt(butter(6, [lo/(SR/2), hi/(SR/2)], btype="band",
                              output="sos"), x)


def beat(x, fmin=0.4, fmax=40.0):
    env = np.abs(hilbert(x))
    env = sosfiltfilt(butter(4, 60/(SR/2), btype="low", output="sos"), env)
    env = env[int(0.4*SR):-int(0.4*SR)]
    e = env - float(np.mean(env))
    n = 1 << 20
    E = np.abs(np.fft.rfft(e * np.hanning(len(e)), n))
    f = np.fft.rfftfreq(n, 1/SR)
    m = (f >= fmin) & (f <= fmax)
    k = int(np.argmax(np.where(m, E, 0)))
    rate = float(f[k])
    mx, mn = float(np.max(env)), float(np.min(env))
    return rate, (mx - mn) / (mx + mn)


rows, bad = [], []
for h in TL["abHalves"]:
    if h["cycle"] != 0:
        continue
    sid, tag = h["stage"], h["tag"]
    # ⚠ TRIM A FULL SECOND OFF EACH END. assemble.py fades each play segment
    # in and out; with only 0.6 s / 0.2 s trimmed, BOTH controls measured a
    # depth of exactly 0.247 — the fade ramp, not beating, and identical to
    # four decimal places across two unrelated pairs, which is what gave it
    # away.
    x = grab(h["startSec"] + 1.2, h["endSec"] - 1.0,
             f"{TMP}/{sid}-{tag}.wav")
    part = PARTIAL.get(sid)
    r, d = beat(bp(x, part) if part else x)
    rows.append((sid, tag, r, d, part))
    print(f"  {sid:14s} {tag:6s}  rate {r:7.3f} Hz   depth {d:.4f}"
          + (f"   (in a {part:.0f} Hz band)" if part else ""))

exp = {("08-measure", "AFTER"): M["beats"]["comma"]["full"]["rateHz"],
       ("11-cost-third", "AFTER"): M["beats"]["thirdET"]["band"]["rateHz"]}
for sid, tag, r, d, _ in rows:
    if tag == "AFTER":
        want = exp[(sid, tag)]
        ok = abs(r - want) < 0.25 and d > 0.25
        print(f"  -> {sid} AFTER: {r:.3f} Hz against the source's {want:.3f} Hz, "
              f"depth {d:.4f}  {'OK' if ok else 'FAIL'}")
        if not ok:
            bad.append(sid)
    else:
        ok = d < 0.10
        print(f"  -> {sid} BEFORE (control): depth {d:.4f}  "
              f"{'OK — flat, as it must be' if ok else 'FAIL — the control beats'}")
        if not ok:
            bad.append(sid + "/control")
sys.exit(f"FAILED: {bad}" if bad else 0)
