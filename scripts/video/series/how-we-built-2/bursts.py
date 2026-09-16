#!/usr/bin/env python3
"""Explode every MOVING shot into a burst directory (numbered frames +
meta.json), which is what assemble.py plays under a stage's audio.

Three sources, all real:
  play-arrange  the app itself, filmed with screenrec while the transport ran
  deadline      the manim explanation of the block deadline
  counter       the manim explanation of the lost counts

⚠ THE APP RECORDING IS TRIMMED. The recorder is started BEFORE the transport
so nothing is missed, which means the first seconds are a still app. TRIM is
the measured gap between the two, so the burst opens on a moving playhead.
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUR = f"{HERE}/bursts"
MAN = f"{HERE}/manim/videos/anim_deadline/1080p60"
FPS = 30
TRIM = 1.6      # seconds of pre-roll in media/play-arrange.mp4 (play at ~1.5 s)

# ⚠ 12.0 s EXACTLY: the clean half of the dropout demonstration is the
# first twelve seconds of this project's render, and the footage under it
# has to be the same twelve seconds of the transport.
SRC = [("play-arrange", f"{HERE}/media/play-arrange.mp4", TRIM, 12.0),
       ("deadline",     f"{MAN}/deadline.mp4",            0.0,  None),
       ("counter",      f"{MAN}/counter.mp4",             0.0,  None)]


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:9])}\n{p.stderr[-1500:]}")
    return p.stdout


out = {}
for name, src, ss, dur in SRC:
    if not os.path.exists(src):
        sys.exit(f"missing source for burst {name}: {src}")
    d = f"{BUR}/{name}"
    # ⚠ CLEAR IT FIRST: a shorter re-run leaves the previous take's tail frames
    # behind and assemble.py globs the directory.
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    if ss:
        cmd += ["-ss", str(ss)]          # ⚠ -ss BEFORE -i
    cmd += ["-i", src]
    if dur:
        cmd += ["-t", str(dur)]
    cmd += ["-vf", f"fps={FPS},scale=1920:1080:flags=lanczos", f"{d}/f%04d.png"]
    run(cmd)
    n = len([f for f in os.listdir(d) if f.startswith("f") and f.endswith(".png")])
    if n < 30:
        sys.exit(f"burst {name}: only {n} frames")
    json.dump({"fps": FPS, "frames": n, "seconds": round(n / FPS, 3)},
              open(f"{d}/meta.json", "w"), indent=1)
    out[name] = round(n / FPS, 3)
    print(f"  {name:14s} {n:4d} frames  {n/FPS:6.2f}s")

json.dump(out, open(f"{HERE}/bursts.json", "w"), indent=1)
