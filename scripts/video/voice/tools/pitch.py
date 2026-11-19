#!/usr/bin/env python3
"""pitch.py — an INDEPENDENT pitch reading of rendered vocal stems.

The app's own readers (the editor's played line, clip.getPlayedPitch) are the
product under test; a film claim like "four notes pulled 70 cents sharp, then
brought back" must also hold on the AUDIO, read by code that shares nothing
with the product. This is a plain YIN (de Cheveigne & Kawahara 2002) in numpy:
per 2048-sample frame (hop 256) at 48 kHz, cumulative-mean-normalised
difference, absolute threshold 0.15, parabolic interpolation. A note's pitch
is the MEDIAN of its voiced frames inside the middle 60 % of the note window
(onsets and glides excluded), so vibrato averages out and a scoop doesn't count.

    pitch.py <spec.json>

spec: {"windows": [{"name", "start", "end", "target"}...],
       "wavs": {"label": path, ...}}
Times are seconds in the WAV (the vocal stems are rendered from the clip's
first beat, so they equal the editor's segment seconds). Prints a table and
writes <spec>.out.json with cents-vs-target per wav per window.

⭐ CONTROLS are part of every spec: notes nobody touched must read the SAME in
every wav (an invariance control), else the reader, not the edit, is moving.
"""
import json, math, sys
import numpy as np
import soundfile as sf

FRAME, HOP, THRESH = 2048, 256, 0.15
FMIN, FMAX = 80.0, 1000.0


def yin_track(x, sr):
    tau_min, tau_max = int(sr / FMAX), int(sr / FMIN)
    out = []
    for start in range(0, len(x) - FRAME - tau_max, HOP):
        fr = x[start:start + FRAME + tau_max]
        if np.sqrt(np.mean(fr[:FRAME] ** 2)) < 1e-3:       # ~ -60 dBFS: silence
            out.append(np.nan)
            continue
        # difference function via autocorrelation identity
        w = FRAME
        d = np.zeros(tau_max + 1)
        x0 = fr[:w]
        e0 = np.dot(x0, x0)
        cs = np.concatenate([[0.0], np.cumsum(fr ** 2)])
        for tau in range(1, tau_max + 1):
            xt = fr[tau:tau + w]
            et = cs[tau + w] - cs[tau]
            d[tau] = e0 + et - 2.0 * np.dot(x0, xt)
        cmnd = np.ones_like(d)
        run = np.cumsum(d[1:])
        cmnd[1:] = d[1:] * np.arange(1, tau_max + 1) / np.where(run == 0, 1, run)
        tau = None
        for t in range(tau_min, tau_max):
            if cmnd[t] < THRESH:
                while t + 1 < tau_max and cmnd[t + 1] < cmnd[t]:
                    t += 1
                tau = t
                break
        if tau is None:
            out.append(np.nan)
            continue
        if 1 <= tau < tau_max:
            a, b, c = cmnd[tau - 1], cmnd[tau], cmnd[tau + 1]
            den = a - 2 * b + c
            shift = 0.5 * (a - c) / den if den != 0 else 0.0
        else:
            shift = 0.0
        out.append(sr / (tau + shift))
    t = (np.arange(len(out)) * HOP + FRAME / 2) / sr
    return t, np.array(out)


def midi(f):
    return 69 + 12 * np.log2(f / 440.0)


def main(spec_path):
    spec = json.load(open(spec_path))
    tracks = {}
    for label, path in spec["wavs"].items():
        x, sr = sf.read(path, always_2d=True)
        x = x.mean(axis=1).astype(np.float64)
        tracks[label] = yin_track(x, sr)
    res = {}
    hdr = f"{'window':<26}{'target':>7}" + "".join(f"{l:>15}" for l in spec["wavs"])
    print(hdr)
    for w in spec["windows"]:
        s, e = w["start"], w["end"]
        lo, hi = s + 0.2 * (e - s), e - 0.2 * (e - s)
        row = f"{w['name']:<26}{w['target']:>7}"
        for label, (t, f) in tracks.items():
            sel = f[(t >= lo) & (t <= hi)]
            sel = sel[np.isfinite(sel)]
            if len(sel) < 3:
                res.setdefault(label, {})[w["name"]] = None
                row += f"{'unvoiced':>15}"
                continue
            mm = midi(sel)
            m = float(np.median(mm))
            cents = (m - w["target"]) * 100
            # WOBBLE: the spread of the pitch around its own straight-line trend,
            # p95 - p5 in cents (a vibrato of +-d cents reads ~2d). Detrended so
            # a slow drift is not counted as vibrato.
            tt = np.arange(len(mm))
            resid = (mm - np.polyval(np.polyfit(tt, mm, 1), tt)) * 100
            wob = float(np.percentile(resid, 95) - np.percentile(resid, 5))
            res.setdefault(label, {})[w["name"]] = {"midi": round(m, 3), "centsVsTarget": round(cents, 1),
                                                   "wobbleCentsP95P5": round(wob, 1),
                                                   "frames": int(len(sel))}
            row += f"{cents:>+8.0f}c w{wob:>4.0f}"
        print(row)
    json.dump(res, open(spec_path.replace(".json", ".out.json"), "w"), indent=2)


if __name__ == "__main__":
    main(sys.argv[1])
