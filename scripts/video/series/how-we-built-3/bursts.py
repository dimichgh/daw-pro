#!/usr/bin/env python3
"""Explode every MOVING shot into a burst directory (numbered frames +
meta.json). sweep.py writes its own two; this handles the app footage and the
manim scene.

⚠ THE APP RECORDING IS TRIMMED. The recorder starts BEFORE the transport so
nothing is missed. TRIM is MEASURED, not assumed: the transport readout is
0:01.465 at film t = 3.000 and 0:10.457 at t = 12.000, so play began at
3.000 - 1.465 = 1.535 s and the two readings agree to 8 ms across 9 seconds.
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUR = f"{HERE}/bursts"
MAN = f"{HERE}/manim/videos/anim_silent/1080p60"
FPS = 30
TRIM = 1.535

SRC = [("play-arrange", f"{HERE}/media/play-arrange.mp4", TRIM, 12.0),
       ("silent",       f"{MAN}/Silent.mp4",              0.0,  None)]


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd[:9])}\n{p.stderr[-1500:]}")


out = json.load(open(f"{HERE}/bursts.json")) if os.path.exists(f"{HERE}/bursts.json") else {}
for name, src, ss, dur in SRC:
    if not os.path.exists(src):
        sys.exit(f"missing source for burst {name}: {src}")
    d = f"{BUR}/{name}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    if ss:
        cmd += ["-ss", str(ss)]
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
    print(f"  {name:16s} {n:4d} frames  {n/FPS:6.2f}s")

json.dump(out, open(f"{HERE}/bursts.json", "w"), indent=1)
