#!/usr/bin/env python3
"""take-motion.py <burst>... — does each screen take MOVE? Changed-pixel count
(luma change > 40) between the frame 2 s and the frame 8 s into bursts/<b>/raw.mp4,
each frame extracted ALONE and compared in numpy. A take must change >= 300
pixels. CONTROLS: the first take's 2 s frame against itself must read 0, and two
frames of a frozen video (one still looped) must read <= 20.

⛔ Replaces record-all.sh's `-ss 2 -i F -ss 8 -i F ... blend=difference` probe:
blend pairs its inputs BY TIMESTAMP after the seeks, so it did not compare 2 s
with 8 s. MEASURED on the finished film: that shape read 0 on a beat whose clock
visibly runs 0:05.834 -> 0:08.618 and 255 on a beat that is one still.
"""
import os, subprocess, sys
import numpy as np
from PIL import Image
HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def frame(src, t, tag):
    p = f"{HOME}/logs/_tm-{tag}.png"
    if os.path.exists(p):
        os.remove(p)
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t}", "-i", src,
                        "-frames:v", "1", p], capture_output=True, text=True)
    if r.returncode or not os.path.exists(p):
        sys.exit(f"⛔ no frame {t}s of {src}: {r.stderr[-300:]}")
    return np.asarray(Image.open(p).convert("L"), float)


changed = lambda a, b: int((np.abs(a - b) > 40).sum())
bad = 0
for b in sys.argv[1:]:
    src = f"{HOME}/bursts/{b}/raw.mp4"
    n = changed(frame(src, 2, "a"), frame(src, 8, "b"))
    ok = n >= 300
    bad += not ok
    print(f"  {b:14s} {'moves' if ok else '⛔ STATIC'} ({n} px changed, 2 s vs 8 s)")
first = f"{HOME}/bursts/{sys.argv[1]}/raw.mp4"
f0 = frame(first, 2, "a")
self_ = changed(f0, frame(first, 2, "b"))
Image.fromarray(f0.astype("uint8")).save(f"{HOME}/logs/_tm-still.png")
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-loop", "1", "-i", f"{HOME}/logs/_tm-still.png",
                "-t", "10", "-r", "30", "-pix_fmt", "yuv420p", f"{HOME}/logs/_tm-frozen.mp4"], check=True)
frozen = changed(frame(f"{HOME}/logs/_tm-frozen.mp4", 2, "a"), frame(f"{HOME}/logs/_tm-frozen.mp4", 8, "b"))
print(f"  CONTROL self {self_} px (must be 0), frozen video {frozen} px (must be <= 20)")
if self_ != 0 or frozen > 20:
    sys.exit("⛔ a control failed — the probe proves nothing")
sys.exit(1 if bad else 0)
