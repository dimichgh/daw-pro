#!/usr/bin/env python3
"""ab-equality.py — is each A/B half IN THE FILM the loop it claims to be?

    plugins/narrated-film/.venv/bin/python tools/ab-equality.py [film]

Every number spoken over an A/B (cents, wobble, centroid ratios) was measured on
loops/*.wav's source renders, not on the film. This carries the measurement
over: each half's decoded audio, at the start/end timeline.json gives, is
correlated against its OWN source loop and against the OTHER half's loop. Own
must be ~1 (AAC only); the other is the CONTROL — if the control also read ~1,
the probe could not tell the halves apart and the "own" figure would prove
nothing. Gain is reported too (normalize:false means it must be ~0 dB).
"""
import json, os, subprocess, sys
import numpy as np

HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
film = sys.argv[1] if len(sys.argv) > 1 else f"{HOME}/out/voice-film.mp4"
tl = json.load(open(film + ".timeline.json"))["abHalves"]
SR, PAD = 48000, 0.25          # stay clear of the assembler's 0.15 s fades


def pcm(path, ss=None, t=None):
    a = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    a += (["-ss", f"{ss:.3f}"] if ss is not None else []) + (["-t", f"{t:.3f}"] if t is not None else [])
    a += ["-i", path, "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"]
    r = subprocess.run(a, capture_output=True)
    if r.returncode:
        sys.exit(f"⛔ ffmpeg failed on {path}: {r.stderr[-300:]}")
    x = np.frombuffer(r.stdout, dtype="float32").astype("float64")
    if len(x) < SR // 2:
        sys.exit(f"⛔ {path}: only {len(x)} samples decoded — the probe saw nothing")
    return x


def best(film_x, src, lag_max=SR // 10):
    """Max normalised correlation of film_x against src over EVERY sample lag in
    ±lag_max around the expected alignment (film_x starts PAD s into src).

    ⚠ Sample-exact, via FFT. A first version searched a 1 ms grid and refined
    around the grid's best: on a SOLO VOICE (a near-periodic signal, period ~3 ms)
    the grid's best was a side lobe one pitch period off, and the hard pair read
    0.54 at -19.0 ms while every other pair read 0.99 at -21.3 ms."""
    off, n = int(PAD * SR), len(film_x)
    lo = max(0, off - lag_max)
    seg = src[lo:off + n + lag_max]
    m = len(seg) - n + 1
    if m < 1:
        return -1.0, 0.0, 0.0
    N = 1 << int(np.ceil(np.log2(len(seg) + n)))
    c = np.fft.irfft(np.fft.rfft(seg, N) * np.conj(np.fft.rfft(film_x, N)), N)[:m]
    e = np.concatenate([[0.0], np.cumsum(seg ** 2)])
    win = np.sqrt(np.maximum(e[n:n + m] - e[:m], 1e-24))
    r = c / (np.linalg.norm(film_x) * win)
    k = int(np.argmax(r))
    gain = 20 * np.log10(np.linalg.norm(film_x) / win[k])
    return float(r[k]), (lo + k - off) / SR * 1000, float(gain)


pairs = {}
for h in tl:
    pairs.setdefault(h["stage"], {})[h["tag"]] = h
rows, bad = [], 0
for stage, p in pairs.items():
    for tag, other in (("BEFORE", "AFTER"), ("AFTER", "BEFORE")):
        h = p[tag]
        x = pcm(film, h["startSec"] + PAD, h["endSec"] - h["startSec"] - 2 * PAD)
        own = best(x, pcm(h["wav"]))
        ctl = best(x, pcm(p[other]["wav"]))
        ok = own[0] > 0.98 and ctl[0] < own[0] - 0.05 and abs(own[2]) < 0.3
        bad += not ok
        rows.append({"stage": stage, "half": tag, "src": os.path.basename(h["wav"]),
                     "ownCorr": round(own[0], 4), "lagMs": round(own[1], 2), "gainDb": round(own[2], 2),
                     "controlCorr": round(ctl[0], 4), "ok": bool(ok)})
        print(f"{stage:7s} {tag:6s} own {own[0]:.4f} (lag {own[1]:+.1f} ms, gain {own[2]:+.2f} dB)"
              f"   vs other half's loop {ctl[0]:.4f}   {'ok' if ok else '⛔'}")
json.dump(rows, open(f"{HOME}/work/ab-equality.json", "w"), indent=1)
print(f"\n{len(rows) - bad}/{len(rows)} halves are their own loop (corr > 0.98, gain within 0.3 dB, control lower by > 0.05)")
sys.exit(1 if bad else 0)
