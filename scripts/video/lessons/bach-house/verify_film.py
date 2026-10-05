#!/usr/bin/env python3
"""Measure the thing the film DEMONSTRATES, off the finished mp4.

verify.py's A/B separation check compares LOUDNESS, and neither of this film's
two demonstrations is a loudness difference:

  07-tempo  is a difference in RATE      — loudness cannot see it.
  15-ab     is a difference in SPECTRUM  — loudness sees only part of it.

So this pulls each A/B half back out of the deliverable at the position
`L5v2.mp4.timeline.json` records, and re-runs the same estimators measure.py
used on the sources. ⚠ 1.0 s is trimmed off each end: assemble fades each half
in and out, and a fade ramp is itself an amplitude event that both estimators
would otherwise report.
"""
import json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FILM = f"{HERE}/out/L5v2.mp4"
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
TL = json.load(open(f"{FILM}.timeline.json"))
SR, TRIM = 48000, 1.0


def grab(t0, t1):
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-v", "error",
                          "-ss", f"{t0:.3f}", "-i", FILM, "-t", f"{t1-t0:.3f}",
                          "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<f4")


def onset_rate(x, lo=2.0, hi=14.0, hop=480):
    n = 2048
    w = np.hanning(n)
    S = np.array([np.abs(np.fft.rfft(x[i:i + n] * w)) for i in range(0, len(x) - n, hop)])
    e = np.maximum(np.diff(S, axis=0), 0).sum(axis=1)
    e = e - e.mean()
    N = 1 << int(np.ceil(np.log2(len(e) * 4)))
    P = np.abs(np.fft.rfft(e * np.hanning(len(e)), N)) ** 2
    f = np.fft.rfftfreq(N, hop / SR)
    sel = (f >= lo) & (f <= hi)
    i = np.where(sel)[0][np.argmax(P[sel])]
    a, b, c = (np.log(P[i - 1] + 1e-30), np.log(P[i] + 1e-30), np.log(P[i + 1] + 1e-30))
    d = 0.5 * (a - c) / (a - 2 * b + c + 1e-30)
    return float(f[i] + d * (f[1] - f[0]))


def band_db(x, lo, hi):
    n, step = 8192, 4096
    w = np.hanning(n)
    acc, k = np.zeros(n // 2 + 1), 0
    for i in range(0, len(x) - n, step):
        acc += np.abs(np.fft.rfft(x[i:i + n] * w)) ** 2
        k += 1
    psd = acc / max(k, 1)
    f = np.fft.rfftfreq(n, 1 / SR)
    return 10 * np.log10(psd[(f >= lo) & (f < hi)].sum() / (n * n / 4) + 1e-20)


out, bad = {}, []
for h in TL["abHalves"]:
    if h["cycle"]:
        continue
    x = grab(h["startSec"] + TRIM, h["endSec"] - TRIM)
    r = {"wav": os.path.basename(h["wav"]), "seconds": round(len(x) / SR, 2)}
    if h["stage"] == "07-tempo":
        r["onsetsPerSec"] = round(onset_rate(x), 3)
    else:
        r["sub100Db"] = round(band_db(x, 20, 100), 2)
        r["midDb"] = round(band_db(x, 250, 1000), 2)
    out.setdefault(h["stage"], {})[h["tag"]] = r
    print(f"  {h['stage']:10s} {h['tag']:6s} {r}")

t = out["07-tempo"]
src = M["tempo"]
for tag, key in (("BEFORE", "slow"), ("AFTER", "fast")):
    got, want = t[tag]["onsetsPerSec"], src[key]["measuredOnsetsPerSec"]
    ok = abs(got - want) < 0.15
    print(f"  tempo {tag}: film {got:.3f} vs source {want:.3f} onsets/s  "
          f"{'ok' if ok else 'FAIL'}")
    if not ok:
        bad.append(f"07-tempo {tag}: {got} vs {want}")
ratio = t["AFTER"]["onsetsPerSec"] / t["BEFORE"]["onsetsPerSec"]
print(f"  tempo ratio in the film: {ratio:.4f}  (source {src['measuredRatio']:.4f}, "
      f"predicted {src['ratio']:.4f})")
if abs(ratio - src["ratio"]) > 0.05:
    bad.append(f"tempo ratio {ratio}")

b = out["15-ab"]
d_sub = b["AFTER"]["sub100Db"] - b["BEFORE"]["sub100Db"]
d_mid = b["AFTER"]["midDb"] - b["BEFORE"]["midDb"]
print(f"  build A/B in the film: {d_sub:+.2f} dB below 100 Hz, {d_mid:+.2f} dB "
      f"in 250 Hz-1 kHz")
if d_sub < 25:
    bad.append(f"15-ab sub-100 delta only {d_sub:.2f} dB — the halves barely differ")
if d_sub - d_mid < 15:
    bad.append("15-ab: the two halves differ as much in the mid as at the bottom, "
               "which is not what the film claims")

json.dump({"halves": out, "tempoRatioInFilm": round(ratio, 4),
           "buildSub100DeltaDb": round(d_sub, 2), "buildMidDeltaDb": round(d_mid, 2)},
          open(f"{HERE}/FILMCHECK.json", "w"), indent=1)
if bad:
    sys.exit("FILM CHECK FAILED:\n  " + "\n  ".join(bad))
print("  FILM CHECK: green")
