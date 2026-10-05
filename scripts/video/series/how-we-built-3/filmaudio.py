#!/usr/bin/env python3
"""Measure the FINISHED FILM's own decoded audio at the four play segments.

⚠ A SEGMENT THAT IS RIGHT ON DISK CAN BE WRONG IN THE FILM. Everything here is
read out of out/HWB3.mp4 after encoding, at offsets computed from the actual
segment durations, with a NEGATIVE CONTROL on every claim.
"""
import json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wav                                                       # noqa: E402

FILM = f"{HERE}/out/HWB3.mp4"
ST = json.load(open(f"{HERE}/chapters.json"))["stageStarts"]


def excerpt(t, secs):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error",
                        "-i", FILM, "-ss", f"{t:.3f}", "-t", f"{secs:.3f}",
                        "-f", "f32le", "-ac", "2", "-ar", "48000", "-"],
                       capture_output=True)
    return np.frombuffer(p.stdout, dtype="<f4").astype(np.float64).reshape(-1, 2)


def db(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)


print("play segments, read back out of the finished mp4:")
res = {}
for sid, secs in (("01-project", 12.0), ("05-listen", 10.1), ("06-lift", 10.1),
                  ("08-before", 6.0), ("09-after", 6.0)):
    a = excerpt(ST[f"{sid}-play"] + 0.15, secs - 0.3)
    res[sid] = a
    print(f"  {sid:12s} start {ST[f'{sid}-play']:8.2f}s  rms {db(a):7.2f} dBFS  "
          f"peak {20*np.log10(np.abs(a).max()+1e-12):7.2f}")

# 1. the quiet pass and the lifted pass must differ by the ONE shared gain
d = db(res["06-lift"]) - db(res["05-listen"])
print(f"\n  lifted minus quiet: {d:+.2f} dB   (the shared gain is +14.00)")

# 2. the deliberate identical A/B — correlate rather than compare levels, because
#    a level test CANNOT see two halves that are the same file. That is the point
#    of the chapter.
n = min(len(res["08-before"]), len(res["09-after"]))
a, b = res["08-before"][:n].mean(1), res["09-after"][:n].mean(1)
r = float(np.corrcoef(a, b)[0, 1])
lvl = db(res["09-after"]) - db(res["08-before"])
# NEGATIVE CONTROL: the same probe against audio that genuinely differs.
# ⚠ THE FIRST CONTROL I CHOSE WAS 01-project's PLAY, and it correlated +0.97 —
# because same-before.wav IS the first six seconds of mix-clean.wav, which is
# what 01-project plays. A control drawn from the same source is not a control.
# The drum pair is unrelated audio.
c = res["05-listen"][:n].mean(1)
rc = float(np.corrcoef(a, c)[0, 1])
print(f"\n  08-before vs 09-after : level {lvl:+.2f} dB, correlation {r:+.4f}")
print(f"  CONTROL 08 vs 05-listen: correlation {rc:+.4f}  (must be far from 1)")
if r < 0.98:
    sys.exit("REFUSING — the two halves were supposed to be the SAME audio "
             f"(the chapter's whole point) and correlate only {r:.3f}")
if abs(rc) > 0.5:
    sys.exit("REFUSING — the control correlates too, so the probe proves nothing")
print("\n  the identical A/B is identical IN THE FILM, and the control says the "
      "probe can tell the difference.")
