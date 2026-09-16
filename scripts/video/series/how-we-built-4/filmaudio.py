#!/usr/bin/env python3
"""Measure the FINISHED FILM's own decoded audio at the four play segments.

⚠ A SEGMENT THAT IS RIGHT ON DISK CAN BE WRONG IN THE FILM. Everything here is
read out of out/HWB4.mp4 after encoding, at offsets computed from the actual
segment durations, with a NEGATIVE CONTROL on every claim.
"""
import json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wav                                                       # noqa: E402

FILM = f"{HERE}/out/HWB4.mp4"
ST = json.load(open(f"{HERE}/chapters.json"))["stageStarts"]


def excerpt(t, secs):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error",
                        "-i", FILM, "-ss", f"{t:.3f}", "-t", f"{secs:.3f}",
                        "-f", "f32le", "-ac", "2", "-ar", "48000", "-"],
                       capture_output=True)
    return np.frombuffer(p.stdout, dtype="<f4").astype(np.float64).reshape(-1, 2)


def db(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)


PLAYS = [("01-project", 12.0), ("03-empty", 17.3), ("06-flam", 7.5),
         ("07-apart", 7.5), ("08-plant", 17.4), ("18-eyes", 11.9)]

print("play segments, read back out of the finished mp4:")
res = {}
for sid, secs in PLAYS:
    t = ST[f"{sid}-play"]
    x = excerpt(t, secs)
    res[sid] = x
    print(f"  {sid:12s} at {t:8.3f}s  rms {db(x):7.2f} dBFS  peak "
          f"{20*np.log10(np.abs(x).max()+1e-12):7.2f} dBFS")

# ── THE A/B: a TIMING demonstration, so level must NOT be the evidence ───────
n = min(len(res["06-flam"]), len(res["07-apart"]))
a = res["06-flam"][:n].mean(1)
b = res["07-apart"][:n].mean(1)
lvl = db(res["07-apart"][:n]) - db(res["06-flam"][:n])
r = float(np.corrcoef(a, b)[0, 1])
print(f"\n  06-flam vs 07-apart : level {lvl:+.2f} dB, correlation {r:+.4f}")
print("  (the pair shares ONE static gain; the difference is timing, not level)")

# ── NEGATIVE CONTROLS — every candidate PRINTED, so the label cannot lie ─────
# ⚠ Part 3's report labelled its control `01-project` while computing a
# different one; I measured that clip at +0.957 with the thing under test, so a
# believed label would have quoted a worthless control as a good one. Here every
# candidate is computed AND printed, and the verdict names the file it used.
print("\n  negative controls (all computed, none assumed):")
best = None
for sid in ("01-project", "03-empty", "08-plant", "18-eyes"):
    c = res[sid][:n].mean(1) if len(res[sid]) >= n else np.pad(
        res[sid].mean(1), (0, n - len(res[sid])))
    rc = float(np.corrcoef(a, c[:n])[0, 1])
    print(f"    06-flam vs {sid:12s} corr {rc:+.6f}")
    if best is None or abs(rc) < abs(best[1]):
        best = (sid, rc)
print(f"  -> control used: {best[0]} at {best[1]:+.6f}; "
      f"separation {abs(r/best[1]):.0f}x")
if abs(best[1]) > 0.2:
    sys.exit("FILMAUDIO REFUSES — no candidate is uncorrelated enough to be a control")
json.dump({"abLevelDb": round(lvl, 3), "abCorr": round(r, 6),
           "controlStage": best[0], "controlCorr": round(best[1], 6),
           "rms": {k: round(float(db(v)), 2) for k, v in res.items()},
           "peak": {k: round(float(20*np.log10(np.abs(v).max()+1e-12)), 2)
                    for k, v in res.items()}},
          open(f"{HERE}/filmaudio.json", "w"), indent=1)
